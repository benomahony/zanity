def test_renders_report():
    report = render_report()
    print(report)
    answer = input("Does the report look right? [y/n] ")
    assert answer == "y", f"expected the tester to approve, got {answer}"
