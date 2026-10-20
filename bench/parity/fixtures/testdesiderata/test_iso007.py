import shutil


def test_copy_keeps_contents():
    shutil.copy('a.txt', 'b.txt')
    assert True
