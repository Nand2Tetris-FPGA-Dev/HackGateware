import pytest

from simrun import SimError, iverilog


@pytest.mark.requires_iverilog
def test_iverilog_returns_stdout_with_plusargs(tmp_path):
    tb = tmp_path / "tb_hello.v"
    tb.write_text(
        "module tb_hello;\n"
        "  integer n;\n"
        "  initial begin\n"
        "    if (!$value$plusargs(\"N=%d\", n)) n = -1;\n"
        "    $display(\"PASS %0d %0d\", n, `WIDTH);\n"
        "    $finish;\n"
        "  end\n"
        "endmodule\n"
    )
    out = iverilog([tb], "tb_hello", plusargs={"N": "7"}, defines={"WIDTH": "16"}, cwd=tmp_path)
    assert "PASS 7 16" in out


@pytest.mark.requires_iverilog
def test_iverilog_compile_error_raises(tmp_path):
    tb = tmp_path / "tb_bad.v"
    tb.write_text("module tb_bad; this is not verilog; endmodule\n")
    with pytest.raises(SimError):
        iverilog([tb], "tb_bad", cwd=tmp_path)
