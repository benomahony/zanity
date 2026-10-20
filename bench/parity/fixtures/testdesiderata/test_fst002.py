import time


def test_job_eventually_finishes(job):
    for _ in range(10):
        if job.done():
            break
        time.sleep(0.1)
    assert job.done()
