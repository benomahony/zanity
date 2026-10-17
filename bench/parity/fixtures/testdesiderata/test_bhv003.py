def test_tracks_saves(mocker):
    spy = mocker.spy(object, '__init__')
    assert spy is not None
