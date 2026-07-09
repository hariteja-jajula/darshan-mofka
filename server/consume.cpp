#include <iostream>
#include <string>
#include <fstream>
#include <sstream>
#include <diaspora/Driver.hpp>
#include <diaspora/TopicHandle.hpp>
#include <diaspora/Consumer.hpp>

int main(int argc, char** argv)
{
    std::string group_file = argv[1];
    std::string topic_name = (argc > 2) ? argv[2] : "darshan";
    int want = (argc > 3) ? std::atoi(argv[3]) : 10;

    std::ifstream f(group_file);
    std::stringstream ss; ss << f.rdbuf();
    std::string opts = std::string("{\"group_file\":\"") + group_file + "\"}";

    auto driver = diaspora::Driver::New("mofka", diaspora::Metadata{opts});
    auto topic  = driver.openTopic(topic_name);
    auto consumer = topic.consumer("darshan-consumer", driver.defaultThreadPool());

    for (int i = 0; i < want; i++) {
        auto event = consumer.pull().wait(10000);
        if (!event) { std::cout << "(timeout waiting for event " << i << ")\n"; break; }
        auto& doc = event->metadata().json();
        std::cout << "[" << i << "] module=" << doc.value("module", "?")
                  << " op=" << doc.value("op", "?")
                  << " file=" << doc.value("file", "?").substr(0, 48)
                  << " len=" << doc.value("len", (int64_t)-1) << "\n";
    }
    std::cout << "--- done consuming topic '" << topic_name << "' ---\n";
    return 0;
}
