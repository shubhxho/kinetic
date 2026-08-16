// kn_threads.hpp — a minimal, deterministic parallel-for.
//
// The only place Kinetic uses threads is the narrowphase, where each candidate
// pair is independent. Results are written into pre-sized per-pair slots and
// merged by the caller in index order, so the parallel and serial paths produce
// bit-identical output. There is no work stealing and no atomics in the result
// path — determinism is worth more here than the last few percent of throughput.
#pragma once

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace kn {

class ThreadPool {
   public:
    static ThreadPool &shared() {
        static ThreadPool pool;
        return pool;
    }

    ThreadPool() {
        unsigned hardware = std::thread::hardware_concurrency();
        workerCount_ = hardware > 2 ? hardware - 1 : 1;
        workers_.reserve(workerCount_);
        for (unsigned i = 0; i < workerCount_; ++i) workers_.emplace_back([this] { workerLoop(); });
    }

    ~ThreadPool() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        wake_.notify_all();
        for (auto &worker : workers_) {
            if (worker.joinable()) worker.join();
        }
    }

    ThreadPool(const ThreadPool &) = delete;
    ThreadPool &operator=(const ThreadPool &) = delete;

    unsigned workerCount() const { return workerCount_; }

    // Runs body(i) for i in [0, count). Blocks until every index has completed.
    // Falls back to a plain loop when the batch is too small to pay for the
    // handoff, which keeps small scenes free of synchronisation overhead.
    void parallelFor(int count, int grainSize, const std::function<void(int)> &body) {
        if (count <= 0) return;
        if (workerCount_ <= 1 || count < grainSize * 2) {
            for (int i = 0; i < count; ++i) body(i);
            return;
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            job_ = &body;
            next_.store(0, std::memory_order_relaxed);
            remaining_.store(count, std::memory_order_relaxed);
            total_ = count;
            grain_ = std::max(1, grainSize);
            generation_++;
        }
        wake_.notify_all();

        // The calling thread participates rather than idling.
        runChunks();

        std::unique_lock<std::mutex> lock(doneMutex_);
        done_.wait(lock, [this] { return remaining_.load(std::memory_order_acquire) == 0; });

        std::lock_guard<std::mutex> lock2(mutex_);
        job_ = nullptr;
    }

   private:
    void runChunks() {
        while (true) {
            int start = next_.fetch_add(grain_, std::memory_order_relaxed);
            if (start >= total_) break;
            int end = std::min(start + grain_, total_);
            for (int i = start; i < end; ++i) (*job_)(i);
            int left = remaining_.fetch_sub(end - start, std::memory_order_acq_rel) - (end - start);
            if (left == 0) {
                std::lock_guard<std::mutex> lock(doneMutex_);
                done_.notify_all();
            }
        }
    }

    void workerLoop() {
        uint64_t seen = 0;
        while (true) {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [&] { return stopping_ || generation_ != seen; });
            if (stopping_) return;
            seen = generation_;
            lock.unlock();
            runChunks();
        }
    }

    std::vector<std::thread> workers_;
    unsigned workerCount_ = 1;

    std::mutex mutex_;
    std::condition_variable wake_;
    std::mutex doneMutex_;
    std::condition_variable done_;

    const std::function<void(int)> *job_ = nullptr;
    std::atomic<int> next_{0};
    std::atomic<int> remaining_{0};
    int total_ = 0;
    int grain_ = 1;
    uint64_t generation_ = 0;
    bool stopping_ = false;
};

}  // namespace kn
