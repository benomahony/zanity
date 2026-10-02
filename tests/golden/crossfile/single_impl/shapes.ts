interface Shape {
  area(): number;
}

class Square implements Shape {
  area(): number {
    return 4;
  }
}

interface Store {
  get(key: string): string;
}

class MemoryStore implements Store {
  get(key: string): string {
    return key;
  }
}

class FileStore implements Store {
  get(key: string): string {
    return key;
  }
}
