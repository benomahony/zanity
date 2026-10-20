import uuid


def test_ids_are_unique():
    assert uuid.uuid4() != uuid.uuid4()
