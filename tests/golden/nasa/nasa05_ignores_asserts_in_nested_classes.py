
def outer():
    class Inner:
        def method(self):
            assert True
            assert False
    pass
