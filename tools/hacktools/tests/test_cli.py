from hacktools.cli import main


def test_cli_error_has_no_traceback(capsys):
    assert main(["hw", "build", "no_such_build"]) == 1
    err = capsys.readouterr().err
    assert err.startswith("error:") and "Traceback" not in err
