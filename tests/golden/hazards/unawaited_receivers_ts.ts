class Queue {
  close(): void {}
}

class Session {
  queue = new Queue();

  async flush(): Promise<void> {}

  async close(): Promise<void> {
    this.queue.close();
    this.flush();
  }
}
