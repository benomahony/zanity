from abc import ABC, abstractmethod


class Repository(ABC):
    @abstractmethod
    def load(self, key): ...


class SqlRepository(Repository):
    def load(self, key):
        return key
