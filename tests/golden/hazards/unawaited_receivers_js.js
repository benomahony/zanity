class Queue {
    close() { }
}
class Session {
    queue = new Queue();
    async flush() { }
    async close() {
        this.queue.close();
        this.flush();
    }
}
