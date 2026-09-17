"""codesum plugin — registration."""

from . import schemas, tools


def register(ctx):
    tools.set_ctx(ctx)
    ctx.register_tool(
        name="summarize_code",
        toolset="codesum",
        schema=schemas.SUMMARIZE_CODE,
        handler=tools.summarize_code,
    )
    ctx.register_command(
        "codesum",
        lambda raw: tools.slash_codesum(raw),
        description="Fast code summary via Cerebras qwen-3.8-27b: /codesum <path> [brief|normal|deep]",
    )
