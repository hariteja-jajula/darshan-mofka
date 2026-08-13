// verify_consumer.cpp -- Phase-0 delivery-verification consumer (SCRATCH; never touches the
// locked upstream install/_mofka/example/consumer.cpp).
//
// PURPOSE
// The Phase-0 barrier (update.md / PHASE0_LOG.md) is: prove that the events the producer pushed
// are DELIVERED and DRAINED end to end -- i.e. "pushed == drained" -- so the measured per-push /
// per-delivered number is trustworthy, not an enqueue-into-a-batch-that-never-shipped artifact.
//
// WHY THIS CONSUMER, NOT THE UPSTREAM EXAMPLE
// The upstream example consumer.cpp uses a data selector that requests the 8-byte payload for
// every even id (consumer.cpp:38-49). That drives MofkaConsumer::requestData()
// (MofkaConsumer.cpp:240-293), a synchronous per-event bulk-RDMA RPC (m_consumer_request_data)
// run on the consumer's SINGLE sender ES (ThreadCount{1}). In jobs 7436175 (cxi) and 7436288
// (tcp) that path produced a 5424-RPC storm over 62s with ZERO events ever surfaced to the loop
// body and ZERO acks -- the deserialize ULT never set a single promise. That is a consumer
// DATA-PATH problem, entirely separate from producer push cost.
//
// For Phase 0 the payload is irrelevant: Darshan's connector pushes METADATA events (JSON), not
// bulk data. So this consumer installs a NULL data selector -- return diaspora::DataDescriptor()
// (size 0). Per MofkaConsumer::requestData (MofkaConsumer.cpp:246-263), a zero-size requested
// descriptor returns early with data.size()==0 and NEVER sends an m_consumer_request_data RPC.
// This is the documented "we are not interested in this event's data" idiom (upstream
// consumer.cpp:47). We still receive and deserialize every event's METADATA via recvBatch
// (MofkaConsumer.cpp:190-220) -- which is exactly the delivery we need to verify.
//
// WHAT IT DOES
//   - opens "mytopic", creates a consumer (Adaptive batch, ThreadCount{1}, null selector, null
//     allocator), and drains with pull().wait(timeout_ms) until NoMoreEvents.
//   - counts received events, tracks id min/max/contiguity, acks periodically (proves the ack
//     RPC path works: LegacyPartitionManager::acknowledge advances the durable cursor).
//   - prints ONE machine-parseable line to stderr:
//       VERIFY received=<n> expected=<N> first_id=<..> last_id=<..> contiguous=<0|1>
//              acks=<..> nomoreevents=<0|1> drain_wall_us=<..>
//     and exits 0 iff received>0 AND (expected<=0 OR received==expected) AND nomoreevents==1.
//
// ARGS: verify_consumer <group-file> [expected-N] [drain-budget-ms] [open-retry-s]
//   expected-N      : if >0, stop as soon as received==expected (default 0 = drain until budget).
//   drain-budget-ms : TOTAL wall-clock budget for the drain (default 120000). We poll with many
//                     SHORT pull().wait() calls (see PULL_MS below) until we have received all
//                     expected events or this budget elapses. Under the sequential produce-then-
//                     drain harness the producer has already flushed durably before this consumer
//                     starts, so the budget only needs to cover the drain itself; it is kept
//                     generous to tolerate a slow cold-start attach.
//   open-retry-s    : how long to retry openTopic() while the producer races to createTopic
//                     (default 90). openTopic throws until "mytopic" exists; retrying HERE (one
//                     process, one consumer registration at cursor 0) avoids the old shell probe
//                     loop, which could either truncate output or consume events and advance the
//                     durable cursor before the real drain. Exactly one consumer is ever created.
//
// !! CRITICAL: per-pull wait MUST be small (<= 2000 ms). Mofka's Promise::State::wait
//    (install/_mofka/include/mofka/Promise.hpp:75) computes the ABT_cond_timedwait deadline as
//        deadline.tv_nsec += timeout_ms*1000*1000;
//    where timeout_ms is `int`. For timeout_ms > 2147 the product timeout_ms*1000*1000 overflows
//    32-bit int and WRAPS NEGATIVE, so the deadline lands in the PAST and wait() returns nullopt
//    IMMEDIATELY (observed: wait(120000) returned an empty optional in 10.7 us, job 7436640). So a
//    single large-timeout pull is a silent no-op. We therefore poll with PULL_MS = 1000 (1000*1e6
//    = 1e9 < INT_MAX, safe) and loop against the wall-clock budget instead. wait(-1) is also safe
//    (it uses ABT_cond_wait, no arithmetic) but would block forever here: a live, caught-up
//    consumer on the Legacy partition never receives NoMoreEvents (YokanEventStore::feed blocks on
//    m_count_cv when caught up), so an unbounded wait after the last event would hang.
//
// EXIT CODE: this process ALWAYS exits 0 (after printing the VERIFY line). Rationale: under a PALS
// MPMD launch (broker : producer : consumer), a NONZERO exit from any section ABORTS the whole job
// and SIGTERMs the still-running producer (exactly what killed job 7436640). The PASS/FAIL decision
// lives in the harness verdict, which parses the VERIFY line's received=/contiguous= fields -- the
// consumer's job is only to drain and report, never to abort the run.
//
// All Mofka/diaspora calls are inside try/catch(const diaspora::Exception&). No raw new/delete.
// NOTE on the null allocator: MofkaConsumer::requestData() DOES invoke the data allocator for
// every event (MofkaConsumer.cpp:251-252, `m_data_allocator(metadata, requested_descriptor)`)
// BEFORE the size-0 short-circuit at :261 (`if(data.size()==0) return data;`). So the allocator
// lambda below IS called once per event -- it simply returns an empty diaspora::DataView{} (size 0,
// no heap allocation) which matches the size-0 descriptor from the null selector and short-circuits
// cleanly with no bulk RPC. The allocator therefore must be provided and correct, but it never
// allocates.

#include <mofka/MofkaDriver.hpp>
#include <diaspora/Driver.hpp>
#include <diaspora/TopicHandle.hpp>
#include <spdlog/spdlog.h>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <chrono>
#include <thread>
#include <string>
#include <limits>

int main(int argc, char** argv) {
    if(argc < 2) {
        std::fprintf(stderr,
            "Usage: %s <group-file> [expected-N] [drain-budget-ms] [open-retry-s]\n", argv[0]);
        return 0; // never abort the MPMD (see header note on exit code)
    }
    const std::string group_file = argv[1];
    const long expected  = (argc > 2) ? std::strtol(argv[2], nullptr, 10) : 0;
    long drain_budget_ms = (argc > 3) ? std::strtol(argv[3], nullptr, 10) : 120000;
    if(drain_budget_ms <= 0) drain_budget_ms = 120000;
    long open_retry_s    = (argc > 4) ? std::strtol(argv[4], nullptr, 10) : 90;
    if(open_retry_s < 0) open_retry_s = 0;

    // Per-pull wait: MUST stay <= 2000 so timeout_ms*1000*1000 does not overflow 32-bit int in
    // Mofka's Promise::State::wait (see header). 1000 ms keeps the deadline arithmetic safe
    // (1e9 < INT_MAX) while still amortizing the poll overhead across the drain budget.
    const int PULL_MS = 1000;

    // Keep the log quiet so the VERIFY line is easy to grep; warnings/criticals still show.
    spdlog::set_level(spdlog::level::warn);

    try {
        diaspora::Metadata options;
        options.json()["group_file"] = group_file;
        options.json()["margo"] = nlohmann::json::object();
        options.json()["margo"]["use_progress_thread"] = true;

        diaspora::Driver driver = diaspora::Driver::New("mofka", options);

        // openTopic throws until the producer has created "mytopic". Retry for up to open_retry_s
        // seconds so a co-launched consumer can attach as soon as the topic appears. This is the
        // ONLY retry: exactly one consumer is created below, at cursor 0, so no events are missed
        // and no output is ever truncated.
        diaspora::TopicHandle topic;
        {
            bool opened = false;
            const auto deadline = std::chrono::steady_clock::now()
                                + std::chrono::seconds(open_retry_s);
            for(;;) {
                try {
                    topic = driver.openTopic("mytopic");
                    opened = true;
                    break;
                } catch(const diaspora::Exception&) {
                    if(std::chrono::steady_clock::now() >= deadline) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(500));
                }
            }
            if(!opened) {
                // Final attempt: let the exception propagate to the outer catch with its message.
                topic = driver.openTopic("mytopic");
            }
        }
        // Progress marker: prove we attached to the topic (unbuffered, survives a late SIGTERM).
        std::fprintf(stderr, "VC attached to topic 'mytopic'\n"); std::fflush(stderr);

        // NULL data selector: we want the event + its metadata, but NONE of its bulk data. This
        // makes requestData() short-circuit (size 0) and never issue a bulk RPC -- the exact path
        // that hung in jobs 7436175/7436288 is bypassed by design.
        diaspora::DataSelector selector =
            [](const diaspora::Metadata&, const diaspora::DataDescriptor&) {
                return diaspora::DataDescriptor(); // no data
            };
        // Null allocator: IS invoked once per event by requestData() (see header note), but only
        // hands back an empty DataView{} (size 0) matching the null selector's size-0 descriptor,
        // so it never allocates and no bulk RPC is issued.
        diaspora::DataAllocator allocator =
            [](const diaspora::Metadata&, const diaspora::DataDescriptor&) {
                return diaspora::DataView{}; // empty
            };

        diaspora::BatchSize   batchSize   = diaspora::BatchSize::Adaptive();
        diaspora::ThreadCount threadCount = diaspora::ThreadCount{1};
        diaspora::Consumer consumer =
            topic.consumer("verifyconsumer", batchSize, threadCount, selector, allocator);
        // topic.consumer(...) subscribes SYNCHRONOUSLY: MofkaConsumer::subscribe() sends the
        // m_consumer_request_events RPC to the partition and waits on the ULTs (MofkaConsumer.cpp:
        // 61-84), so by the time this returns the server-side feed loop is running with the durable
        // cursor at id 0. Under the sequential produce-then-drain harness the producer has ALREADY
        // pushed all N events and blocked on flush().wait(-1) (durable in the Yokan store) before
        // this consumer is launched, so subscribing at cursor 0 here immediately sees num_available
        // == N and drains ids 0..N-1 with no co-launch race and no missed early ids.
        std::fprintf(stderr, "VC consumer created; draining (budget=%ldms pull=%dms expected=%ld)\n",
                     drain_budget_ms, PULL_MS, expected); std::fflush(stderr);

        using clock = std::chrono::steady_clock;
        const auto t0 = clock::now();
        const auto deadline = t0 + std::chrono::milliseconds(drain_budget_ms);

        uint64_t received = 0;
        uint64_t acks     = 0;
        uint64_t first_id = std::numeric_limits<uint64_t>::max();
        uint64_t last_id  = 0;
        bool contiguous   = true;      // ids arrive 0,1,2,... with no gap/dup
        bool saw_nomore   = false;
        uint64_t next_expected_id = 0;

        // Idle-stop: once we HAVE received at least one event, if we then go IDLE_STOP_MS with no
        // new event we consider the stream drained and stop (a live Legacy consumer never gets
        // NoMoreEvents, so this bounded idle is how we detect "caught up" without hanging to the
        // full budget). Before the first event we keep polling to the full budget (covers a slow
        // cold-start attach). A heartbeat every ~2 s gives visibility even if SIGTERM'd late.
        const int64_t IDLE_STOP_MS = 5000;
        auto last_event_at = clock::now();
        auto last_beat_at  = clock::now();

        while(clock::now() < deadline) {
            auto opt_event = consumer.pull().wait(PULL_MS);
            const auto now = clock::now();
            if(now - last_beat_at >= std::chrono::milliseconds(2000)) {
                std::fprintf(stderr, "VC heartbeat received=%llu last_id=%llu elapsed_ms=%lld\n",
                             static_cast<unsigned long long>(received),
                             static_cast<unsigned long long>(last_id),
                             static_cast<long long>(
                                 std::chrono::duration_cast<std::chrono::milliseconds>(now - t0).count()));
                std::fflush(stderr);
                last_beat_at = now;
            }
            if(!opt_event) {
                // Nothing available within this short wait. If we've already received events and
                // have now been idle past IDLE_STOP_MS, the stream is drained -> stop. Otherwise
                // keep polling (still within the cold-start attach window before the first event).
                if(received > 0 &&
                   std::chrono::duration_cast<std::chrono::milliseconds>(now - last_event_at).count()
                       >= IDLE_STOP_MS) {
                    break;
                }
                continue;
            }
            const diaspora::Event& event = opt_event.value();
            const uint64_t id = event.id();
            if(id == diaspora::NoMoreEvents) {
                saw_nomore = true;
                break;
            }
            ++received;
            last_event_at = now;
            if(id < first_id) first_id = id;
            if(id > last_id)  last_id  = id;
            if(id != next_expected_id) contiguous = false;
            next_expected_id = id + 1;

            // Ack periodically to exercise the ack path (advances the durable cursor) without an
            // RPC per event. Ack the final event too so the cursor reflects a full drain.
            if((received % 100) == 0) { event.acknowledge(); ++acks; }

            if(expected > 0 && received >= static_cast<uint64_t>(expected)) {
                // Got everything we were told to expect; ack the final event and stop. We do NOT
                // wait for NoMoreEvents -- a live Legacy-partition consumer never gets one.
                event.acknowledge(); ++acks;
                break;
            }
        }

        const auto t1 = clock::now();
        const int64_t drain_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();

        if(first_id == std::numeric_limits<uint64_t>::max()) first_id = 0; // nothing received

        std::fprintf(stderr,
            "VERIFY received=%llu expected=%ld first_id=%llu last_id=%llu "
            "contiguous=%d acks=%llu nomoreevents=%d drain_wall_us=%.1f\n",
            static_cast<unsigned long long>(received), expected,
            static_cast<unsigned long long>(first_id),
            static_cast<unsigned long long>(last_id),
            contiguous ? 1 : 0,
            static_cast<unsigned long long>(acks),
            saw_nomore ? 1 : 0,
            drain_ns / 1000.0);

        // ALWAYS exit 0: the VERIFY line above is the machine-parseable result the harness verdict
        // consumes. A nonzero exit here would abort the PALS MPMD and SIGTERM the producer (job
        // 7436640). Whether this run PASSES is decided by the harness from received=/contiguous=.
        return 0;

    } catch(const diaspora::Exception& ex) {
        // Report but still exit 0 so a consumer-side error cannot abort the whole MPMD run. The
        // absent/short VERIFY line will make the harness mark the run FAIL on its own.
        spdlog::critical("verify_consumer: {}", ex.what());
        std::fprintf(stderr, "VERIFY received=0 expected=%ld first_id=0 last_id=0 "
                             "contiguous=0 acks=0 nomoreevents=0 drain_wall_us=0.0 error=1\n",
                     (argc > 2) ? std::strtol(argv[2], nullptr, 10) : 0);
        return 0;
    }
}
