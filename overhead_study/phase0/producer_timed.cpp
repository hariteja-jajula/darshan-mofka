// producer_timed.cpp -- Phase-0 instrumented copy of Mofka's own example producer.
//
// Purpose: establish the REAL per-push cost of a Mofka producer using Mofka's own
// canonical push path (no Darshan, no custom ring buffer), so we have ground truth
// before rewriting the connector. This is a copy of
//   install/_mofka/example/producer.cpp
// with a minimal, clearly-scoped set of changes over the upstream example:
//
//   1. event count parameterized via argv[2] (default 100000) so the average is
//      meaningful;
//   2. the data-view offset wrapped to (i % 1000) * 8 -- the upstream example indexes
//      buffer.data() + i*8 into an 8000-byte buffer, which is fine at 1000 iters (max
//      offset 8000) but reads far out of bounds at 100k (i*8 -> 800000). Wrapping keeps
//      the same 8-byte views while staying in bounds, so the timing is not measuring UB;
//   3. the per-event spdlog::info removed and the log level raised to warn, so logging
//      does not run 100k times and dominate the timed region;
//   4. steady_clock timing of push() and flush() SEPARATELY, plus the whole loop, printed
//      as one aggregate PHASE0 line to stderr at the end;
//   5. the FINAL flush is BLOCKING -- producer.flush().wait(-1) -- so the timed region
//      captures actual batch DELIVERY to the broker, not just enqueue. Rationale, verified
//      from the Mofka/diaspora source in this tree:
//        - diaspora/Producer.hpp: flush() "is a non-blocking call returning a future that
//          can be awaited"; Future::wait(timeout_ms<=0) blocks until complete
//          (diaspora/Future.hpp:71, ActiveProducerBatchQueue::flush wait callback).
//        - MofkaProducer::~MofkaProducer() calls flush() but DROPS the returned future,
//          and push()/flush() themselves are fire-and-forget. So the upstream example
//          (which also drops every future) can EXIT before its Adaptive batches are
//          transmitted -- nothing is durably stored, and a consumer then subscribes to an
//          empty partition (LegacyPartitionManager::feedConsumer returns count==0 ->
//          NoMoreEvents). Awaiting the final flush is the documented way ("can be awaited")
//          to guarantee delivery, and mirrors the proven connector's blocking
//          diaspora_producer_flush_timeout() before teardown.
//      The in-loop flush-every-100 stays fire-and-forget so avg_push_us / avg_flush_us
//      still measure the cheap enqueue path; only the single final flush is awaited, and
//      its wait time is reported separately as final_flush_us so the two costs never mix.
//   6. an OPTIONAL pre-push warmup sleep (env DARSHAN_P0_PRESLEEP_S, default 0 = faithful
//      to the example) so a subscriber can attach before pushing when a test wants it.
//
// The Mofka API usage (Adaptive batch, ThreadCount{1}, Ordering::Strict, fire-and-forget
// per-event push, flush every 100) is otherwise unchanged from the upstream example.

#include <mofka/MofkaDriver.hpp>
#include <diaspora/Driver.hpp>
#include <diaspora/TopicHandle.hpp>
#include <spdlog/spdlog.h>
#include <fmt/format.h>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <chrono>
#include <string>
#include <vector>
#include <iostream>
#include <thread>

int main(int argc, char** argv) {
    if(argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <group-file> [num-events]" << std::endl;
        return -1;
    }
    std::string g_group_file = argv[1];
    const size_t N = (argc > 2) ? std::strtoull(argv[2], nullptr, 10) : 100000;
    if(N == 0) {
        std::cerr << "num-events must be > 0" << std::endl;
        return -1;
    }
    // Optional warmup: give a subscriber time to attach before we push. Default 0 keeps
    // the run faithful to the upstream example (no artificial delay).
    long presleep_s = 0;
    if(const char* e = std::getenv("DARSHAN_P0_PRESLEEP_S")) {
        presleep_s = std::strtol(e, nullptr, 10);
        if(presleep_s < 0) presleep_s = 0;
    }
    // Quiet: the upstream per-event info log would run N times and dominate the timer.
    spdlog::set_level(spdlog::level::warn);

    try {

        diaspora::Metadata options;
        options.json()["group_file"] = g_group_file;
        options.json()["margo"] = nlohmann::json::object();
        options.json()["margo"]["use_progress_thread"] = true;

        // -- Create MofkaDriver
        diaspora::Driver driver = diaspora::Driver::New("mofka", options);

        // -- Create a topic
        diaspora::Validator         validator;
        diaspora::Serializer        serializer;
        diaspora::PartitionSelector selector;
        driver.createTopic("mytopic", diaspora::Metadata{}, validator, selector, serializer);

        driver.as<mofka::MofkaDriver>().addLegacyPartition("mytopic", 0);

        diaspora::TopicHandle topic = driver.openTopic("mytopic");

        // -- Get a producer for the topic (same config as the upstream example)
        diaspora::BatchSize   batchSize   = diaspora::BatchSize::Adaptive();
        diaspora::ThreadCount threadCount = diaspora::ThreadCount{1};
        diaspora::Ordering    ordering    = diaspora::Ordering::Strict;
        diaspora::Producer    producer    = topic.producer("myproducer", batchSize, threadCount, ordering);

        // The topic + partition now exist; let a consumer attach if the test asked for it.
        if(presleep_s > 0) {
            std::fprintf(stderr, "PHASE0 presleep_s=%ld (waiting for subscriber)\n", presleep_s);
            std::this_thread::sleep_for(std::chrono::seconds(presleep_s));
        }

        srand(time(nullptr));

        // -- Initialize some random data to be sent
        std::vector<char> buffer(8000);
        for(auto& c : buffer) c = 'A' + (rand() % 26);

        // -- Produce events, timing push() and flush() separately.
        using clock = std::chrono::steady_clock;
        int64_t push_ns = 0;    // summed duration of producer.push() calls
        int64_t flush_ns = 0;   // summed duration of in-loop (fire-and-forget) flush calls
        size_t  n_push = 0;
        size_t  n_flush = 0;

        const auto loop_t0 = clock::now();
        for(size_t i = 0; i < N; ++i) {
            auto j = rand() % 100;
            // metadata formatting is deliberately OUTSIDE the push timer.
            diaspora::Metadata metadata = fmt::format("{{\"id\": {}, \"value\": {}}}", i, j);
            diaspora::DataView data{buffer.data() + (i % 1000) * 8, 8};

            const auto p0 = clock::now();
            auto future = producer.push(metadata, data);
            const auto p1 = clock::now();
            push_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(p1 - p0).count();
            ++n_push;
            // Per-event future intentionally dropped (fire-and-forget), as in the example.
            (void)future;

            if(i % 100 == 0) {
                // In-loop flush is left fire-and-forget so this timer keeps measuring the
                // cheap "request a flush" cost, matching the example's flush-every-100.
                const auto f0 = clock::now();
                producer.flush();
                const auto f1 = clock::now();
                flush_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(f1 - f0).count();
                ++n_flush;
            }
        }
        // Final flush is BLOCKING: wait(-1) blocks until every batch is actually delivered
        // to the broker, so the pipeline is durable before we stop timing and exit. This is
        // the one change from the example that guarantees delivery. Its cost is reported
        // separately (final_flush_us) and NOT folded into avg_flush_us.
        const auto ff0 = clock::now();
        auto flush_future = producer.flush();
        flush_future.wait(-1);
        const auto ff1 = clock::now();
        const int64_t final_flush_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(ff1 - ff0).count();

        const auto loop_t1 = clock::now();
        const int64_t loop_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(loop_t1 - loop_t0).count();

        const double total_push_us  = push_ns / 1000.0;
        const double total_flush_us = flush_ns / 1000.0;
        const double avg_push_us    = total_push_us / static_cast<double>(n_push);
        const double avg_flush_us   = n_flush ? total_flush_us / static_cast<double>(n_flush) : 0.0;
        const double final_flush_us = final_flush_ns / 1000.0;
        const double loop_wall_us   = loop_ns / 1000.0;
        // Amortized per-event cost INCLUDING durable delivery: the whole timed region
        // (all pushes + all flushes + the blocking final flush) divided by N. This is the
        // number to compare against the meeting's ~8us delivered-per-event assertion.
        const double avg_delivered_us = loop_wall_us / static_cast<double>(N);

        std::fprintf(stderr,
            "PHASE0 pushes=%zu total_push_us=%.1f avg_push_us=%.3f "
            "flushes=%zu total_flush_us=%.1f avg_flush_us=%.3f "
            "final_flush_us=%.1f loop_wall_us=%.1f avg_delivered_us=%.3f\n",
            n_push, total_push_us, avg_push_us,
            n_flush, total_flush_us, avg_flush_us,
            final_flush_us, loop_wall_us, avg_delivered_us);

    } catch(const diaspora::Exception& ex) {
        spdlog::critical("{}", ex.what());
        exit(-1);
    }

    return 0;
}
