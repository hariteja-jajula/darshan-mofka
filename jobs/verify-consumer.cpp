// Drains the darshan topic and tallies events per (hostname, op). Proves the
// multi-node push worked: events should carry >1 distinct hostname.
#include <iostream>
#include <string>
#include <map>
#include <diaspora/Driver.hpp>
#include <diaspora/TopicHandle.hpp>
#include <diaspora/Consumer.hpp>

int main(int argc, char** argv)
{
    std::string group_file = argv[1];
    std::string topic_name = (argc > 2) ? argv[2] : "darshan";
    int want = (argc > 3) ? std::atoi(argv[3]) : 200;
    int timeout_ms = (argc > 4) ? std::atoi(argv[4]) : 8000;

    std::string opts = std::string("{\"group_file\":\"") + group_file + "\"}";
    auto driver = diaspora::Driver::New("mofka", diaspora::Metadata{opts});
    auto topic  = driver.openTopic(topic_name);
    auto consumer = topic.consumer("verify-consumer", driver.defaultThreadPool());

    std::map<std::string,int> per_host;
    std::map<std::string,int> per_op;
    int n = 0;
    for (int i = 0; i < want; i++) {
        auto event = consumer.pull().wait(timeout_ms);
        if (!event) break;
        auto& doc = event->metadata().json();
        per_host[doc.value("hostname", "?")]++;
        per_op[doc.value("op", "?")]++;
        n++;
    }

    std::cout << "=== consumed " << n << " events ===\n";
    std::cout << "-- per hostname --\n";
    for (auto& kv : per_host) std::cout << "  " << kv.first << " : " << kv.second << "\n";
    std::cout << "-- per op --\n";
    for (auto& kv : per_op) std::cout << "  " << kv.first << " : " << kv.second << "\n";
    std::cout << "distinct_hosts=" << per_host.size() << "\n";
    return 0;
}
