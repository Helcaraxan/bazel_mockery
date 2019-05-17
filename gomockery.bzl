load("@io_bazel_rules_go//go:def.bzl", "go_library", "go_context", "go_path", "go_rule")
load("@io_bazel_rules_go//go/private:providers.bzl", "GoLibrary", "GoPath", "GoSource")

_MOCKERY_TOOL = "@com_github_vektra_mockery//cmd/mockery:mockery"
_TESTIFY_MOCK_LIB = "@com_github_stretchr_testify//mock:go_default_library"

_LIB_DEFAULT_LABEL = "go_default_library"
_MOCKS_DEFAULT_LABEL = "go_default_mocks"
_MOCKS_GOPATH_LABEL = "_mocks_gopath"

def go_mockery(src, importpath, interfaces, visibility, **kwargs):
    mocks_name = kwargs.get("mocks_name", _MOCKS_DEFAULT_LABEL)

    go_mockery_without_library(
        name = mocks_name,
        src = src,
        interfaces = interfaces,
        case = kwargs.get("case", "underscore"),
        outpkg = kwargs.get("outpkg", None),
        mockery_tool = kwargs.get("mockery_tool", None),
        visibility = visibility,
    )

    go_library(
        name = kwargs.get("name", _LIB_DEFAULT_LABEL),
        srcs = [mocks_name],
        importpath = importpath,
        deps = [
            mocks_name,
            kwargs.get("testify_mock_lib", _TESTIFY_MOCK_LIB),
        ],
        visibility = visibility,
    )

def go_mockery_without_library(src, interfaces, visibility, **kwargs):
    interfaces = [ ifce.strip() for ifce in interfaces ]

    case = kwargs.get("case", "underscore")
    genfiles = [ _interface_to_case(ifce, case) + ".go" for ifce in interfaces ]

    go_path(
        name = _MOCKS_GOPATH_LABEL,
        deps = [src],
        visibility = ["//visibility:private"]
    )

    _go_mockery(
        name = kwargs.get("name", _MOCKS_DEFAULT_LABEL),
        src = src,
        interfaces = interfaces,
        case = case,
        outpkg = kwargs.get("outpkg", "mocks"),
        outputs = genfiles,
        gopath_dep = _MOCKS_GOPATH_LABEL,
        mockery_tool = kwargs.get("mockery_tool", _MOCKERY_TOOL),
        visibility = visibility,
    )

def _go_mockery_impl(ctx):
    args = ["-dir", "$GOPATH/src/" + ctx.attr.src[GoLibrary].importpath]
    args += ["-outpkg", ctx.attr.outpkg]
    args += ["-output", ctx.outputs.outputs[0].dirname ]
    args += ["-name", "\"" + "|".join(ctx.attr.interfaces) + "\""]
    args += ["-case", ctx.attr.case]

    _go_tool_run_shell_stdout(
        ctx = ctx,
        cmd = ctx.file.mockery_tool,
        args = args,
        extra_inputs = ctx.attr.src[GoSource].srcs,
        outputs = ctx.outputs.outputs
    )

    go = go_context(ctx)
    library = go.new_library(go)

    return [
        library,
        DefaultInfo(
            files = depset(ctx.outputs.outputs),
        ),
    ]

_go_mockery = go_rule(
    _go_mockery_impl,
    attrs = {
        "src": attr.label(
            doc = "The Go package of which the sources define the interfaces for which to generate mocks.",
            providers = [GoLibrary, GoSource],
            mandatory = True,
        ),
        "interfaces": attr.string_list(
            doc = "The names of the Go interfaces for which to generate mocks. Unlike 'mockery' itself regular expressions are not accepted.",
            mandatory = True,
        ),
        "case": attr.string(
            doc = "The casing of the generated mock filenames. Should be one of ('underscore', 'camel', 'snake')",
            values = [
                "camel",
                "snake",
                "underscore",
            ],
            default = "underscore",
            mandatory = False,
        ),
        "outpkg": attr.string(
            doc = "Import name for the generated mocks package.",
            default = "mocks",
            mandatory = False,
        ),
        "outputs": attr.output_list(
            doc = "The Go source files that will generated and contain the mocks of the targeted interfaces from the specified package.",
            mandatory = True,
        ),
        "gopath_dep": attr.label(
            doc = "The go_path used to create the GOPATH for the mocks package. Is automatically populated by the gomockery macro.",
            providers = [GoPath],
            mandatory = False,
        ),
        "mockery_tool": attr.label(
            doc = "The target of the mockery tool to run.",
            default = Label(_MOCKERY_TOOL),
            allow_single_file = True,
            executable = True,
            cfg = "host",
            mandatory = False,
        ),
    }
)

def _go_tool_run_shell_stdout(ctx, cmd, args, extra_inputs, outputs):
    go_ctx = go_context(ctx)
    gopath = "$(pwd)/" + ctx.var["BINDIR"] + "/" + ctx.attr.gopath_dep[GoPath].gopath

    inputs = [cmd, go_ctx.go] + (
        ctx.attr.gopath_dep.files.to_list() +
        go_ctx.sdk.headers + go_ctx.sdk.srcs + go_ctx.sdk.tools
    ) + extra_inputs

    # We can use the go binary from the stdlib for most of the environment
    # variables, but our GOPATH is specific to the library target we were given.
    # We also, unfortunately, need to do some dirty & porcelain sed'ing on the
    # generated mock files as their import header will be messed up.
    ctx.actions.run_shell(
        outputs = outputs,
        inputs = inputs,
        command = """
           $PWD/{godir}/go env >go_env.txt &&
           source go_env.txt &&
           export $(cut -d= -f1 go_env.txt) &&
           export PATH=$GOROOT/bin:$PWD/{godir}:$PATH &&
           export GOPATH={gopath} &&
           {cmd} {args} >/dev/null 2>&1 &&
           sed -E -i.bak -e 's@"[^"]+{godep}/src/([^"]+)/"@"\\1"@g' {outfiles}
        """.format(
            godep = ctx.attr.gopath_dep[GoPath].gopath,
            godir = go_ctx.go.path[:-1 - len(go_ctx.go.basename)],
            gopath = gopath,
            cmd = "$(pwd)/" + cmd.path,
            args = " ".join(args),
            outfiles = " ".join([ outfile.path for outfile in outputs ]),
        )
    )

# This transformation logic should mirror the one used in
# https://github.com/vektra/mockery/tree/master/mockery/outputter.go
# It is relatively challenging given the limitations of the Starlark
# language: no regular expressions and no 'while' loops.
def _interface_to_case(name, case):
    if case != "underscore":
        return name + "mock"

    transformed = ""
    idx = -1

    # We reflect the parsing state via the 'state' variable.
    # 0 - Parsing until the end of a 'Cased' word.
    # 1 - Parsing until the end of a potential uppercase block.
    state = 0

    curr_word_start = 0

    for idx in range(1, len(name)):
        if state == 0:
            if name[idx].isupper():
                if idx == curr_word_start + 1:
                    state = 1
                    continue

                if curr_word_start > 0:
                    transformed += "_"
                transformed += name[curr_word_start:idx].lower()
                curr_word_start = idx
        elif state == 1:
            if not name[idx].isupper():
                if curr_word_start > 0:
                    transformed += "_"
                transformed += name[curr_word_start:idx-1].lower()
                curr_word_start = idx - 1
                state = 0
        else:
            fail("reached an unexpected parsing state")

    if curr_word_start > 0:
        transformed += "_"
    transformed += name[curr_word_start:].lower()

    return transformed + "_mock"
