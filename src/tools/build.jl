module BuildTools

const COMONICON_URL = "https://github.com/Roger-luo/Comonicon.jl"
export install, build

using Logging
using PackageCompiler
using Pkg.TOML
using Pkg.PlatformEngines
using ..Comonicon
using ..Comonicon.Configurations
using ..Comonicon.Parse
using ..Comonicon.CodeGen
using ..Comonicon.PATH
using ..Comonicon.Types
using ..Comonicon.Tools

function install(m::Module; kwargs...)
    configs = read_configs(m; kwargs...)
    return install(m, configs)
end

function print_install_help(io::IO)
    println(io, "Comonicon - Installation CLI.")
    println(io)
    println(io, "Install the CLI script to `.julia/bin` if not specified with subcommands.")
    println(io)
    printstyled(io, "USAGE\n\n"; bold = true)
    printstyled(io, " "^4, "julia --project deps/build.jl [command]\n\n"; color = :cyan)
    printstyled(io, "COMMAND\n\n"; bold = true)

    printstyled(io, " "^4, "app"; color = :light_blue, bold = true)
    printstyled(io, " [tarball]"; color = :blue)
    println(io, " "^15, "build the application, optionally make a tarball.\n")

    printstyled(io, " "^4, "sysimg"; color = :light_blue, bold = true)
    printstyled(io, " [tarball]"; color = :blue)
    println(io, " "^12, "build the system image, optionally make a tarball.\n")

    printstyled(io, " "^4, "tarball"; color = :light_blue, bold = true)
    println(io, " "^21, "build application and system image then make tarballs")
    println(io, " "^32, "for them.\n")

    printstyled(io, "EXAMPLE\n\n"; bold = true)
    printstyled(io, " "^4, "julia --project deps/build.jl sysimg\n\n"; color = :cyan)
    println(
        io,
        " "^4,
        "build the system image in the path defined by Comonicon.toml or in deps by default.\n\n",
    )
    printstyled(io, " "^4, "julia --project deps/build.jl sysimg tarball\n\n"; color = :cyan)
    println(io, " "^4, "build the system image then make a tarball on this system image.\n\n")
    printstyled(io, " "^4, "julia --project deps/build.jl app tarball\n\n"; color = :cyan)
    println(
        io,
        " "^4,
        "build the application based on Comonicon.toml and make a tarball from it.\n\n",
    )
end

function install(m::Module, configs::Configurations.Comonicon)
    if isempty(ARGS)
        if configs.install.quiet
            logger = NullLogger()
        else
            logger = ConsoleLogger()
        end

        with_logger(logger) do
            install_script(m, configs)
        end
        return
    elseif "-h" in ARGS || "--help" in ARGS || "help" in ARGS
        return print_install_help(stdout)
    elseif first(ARGS) == "sysimg" && !isnothing(configs.sysimg)
        if length(ARGS) == 1
            return build_sysimg(m, configs)
        elseif length(ARGS) == 2 && ARGS[2] == "tarball"
            return build_tarball_sysimg(m, configs)
        end
    elseif first(ARGS) == "app" && !isnothing(configs.application)
        if length(ARGS) == 1
            return build_application(m, configs)
        elseif length(ARGS) == 2 && ARGS[2] == "tarball"
            return build_tarball_app(m, configs)
        end
    elseif first(ARGS) == "tarball" && (!isnothing(configs.sysimg) || !isnothing(configs.application))
        if length(ARGS) == 1
            return build_tarball(m, configs)
        end
    end

    printstyled("target $(join(ARGS, " ")) not found"; color = :red)
    print_install_help(stdout)
    return
end

"install a script as the CLI"
function install_script(m::Module, configs::Configurations.Comonicon)
    bin = expanduser(joinpath(configs.install.path, "bin"))
    shadow = joinpath(bin, configs.name * ".jl")

    if isnothing(configs.sysimg)
        sysimg = nothing
    else
        download_sysimg(m, configs)
        sysimg = PATH.project(m, configs.sysimg.path, "lib", PATH.sysimg(configs.name))
    end

    shell_script = cmd_script(
        m,
        shadow;
        sysimg = sysimg,
        compile = configs.install.compile,
        optimize = configs.install.optimize,
    )
    file = joinpath(bin, configs.name)

    # start writing
    if !ispath(bin)
        @info "cannot find Julia bin folder creating $bin"
        mkpath(bin)
    end

    # generate contents
    @info "generating $shadow"
    open(shadow, "w+") do f
        println(
            f,
            "#= generated by Comonicon for $(configs.name) =# using $m; exit($m.command_main())",
        )
    end

    @info "generating $file"
    open(file, "w+") do f
        println(f, shell_script)
    end

    if configs.install.completion
        install_completion(m, configs)
    end

    chmod(file, 0o777)
    return
end

function install_completion(m::Module, configs::Configurations.Comonicon)
    completions_dir = expanduser(joinpath(configs.install.path, "completions"))
    sh = detect_shell()
    sh === nothing && return

    @info "generating auto-completion script for $sh"
    script = completion_script(sh, m)
    script === nothing && return

    if !ispath(completions_dir)
        mkpath(completions_dir)
    end

    completion_file = joinpath(completions_dir, "_" * configs.name)
    @info "writing to $completion_file"
    write(completion_file, script)
    return
end

function build_sysimg(
    m::Module,
    configs::Configurations.Comonicon;
    # allow override these two options
    incremental = configs.sysimg.incremental,
    filter_stdlibs = configs.sysimg.filter_stdlibs,
    cpu_target = configs.sysimg.cpu_target,
)
    lib = PATH.project(m, configs.sysimg.path, "lib")
    if !ispath(lib)
        @info "creating library path: $lib"
        mkpath(lib)
    end

    @info "compile under project: $(PATH.project(m))"
    @info configs.sysimg

    if incremental != configs.sysimg.incremental
        @info "incremental override to $incremental"
    end

    if filter_stdlibs != configs.sysimg.filter_stdlibs
        @info "filter_stdlibs override to $filter_stdlibs"
    end

    if cpu_target != configs.sysimg.cpu_target
        @info "cpu_target override to $cpu_target"
    end

    exec_file = map(x -> PATH.project(m, x), configs.sysimg.precompile.execution_file)
    stmt_file = map(x -> PATH.project(m, x), configs.sysimg.precompile.statements_file)

    create_sysimage(
        nameof(m);
        sysimage_path = joinpath(lib, PATH.sysimg(configs.name)),
        incremental = incremental,
        filter_stdlibs = filter_stdlibs,
        project = PATH.project(m),
        precompile_execution_file = exec_file,
        precompile_statements_file = stmt_file,
        cpu_target = cpu_target,
    )

    return
end

function build_application(m::Module, configs::Configurations.Comonicon)
    build_dir = PATH.project(m, configs.application.path, configs.name)
    if !ispath(build_dir)
        @info "creating build path: $build_dir"
        mkpath(build_dir)
    end

    @info configs.application

    exec_file = map(x -> PATH.project(m, x), configs.application.precompile.execution_file)
    stmt_file = map(x -> PATH.project(m, x), configs.application.precompile.statements_file)
    create_app(
        PATH.project(m),
        build_dir;
        app_name = configs.name,
        precompile_execution_file = exec_file,
        precompile_statements_file = stmt_file,
        incremental = configs.application.incremental,
        filter_stdlibs = configs.application.filter_stdlibs,
        force = true,
        cpu_target = configs.application.cpu_target,
    )

    if configs.install.completion
        @info "generating completion scripts"
        build_completion(m, configs)
    end
    return
end

function build_tarball(m::Module, configs::Configurations.Comonicon)
    build_tarball_app(m, configs)
    build_tarball_sysimg(m, configs)
    return
end

function build_tarball_app(m::Module, configs::Configurations.Comonicon)
    isnothing(configs.application) && return
    @info "building application"
    build_application(m, configs)
    # pack tarball
    tarball = tarball_name(m, configs.name; application = true)
    @info "creating application tarball $tarball"
    cd(PATH.project(m, configs.application.path)) do
        run(`tar -czvf $tarball $(configs.name)`)
    end
    return
end

function build_tarball_sysimg(m::Module, configs::Configurations.Comonicon)
    isnothing(configs.sysimg) && return

    @info "building system image"
    build_sysimg(m, configs)
    # pack tarball
    tarball = tarball_name(m, configs.name)
    @info "creating system image tarball $tarball"
    cd(PATH.project(m, configs.sysimg.path)) do
        run(`tar -czvf $tarball lib`)
    end
    return
end

function download_sysimg(m::Module, configs::Configurations.Comonicon)
    url = sysimg_url(m, configs)
    PlatformEngines.probe_platform_engines!()

    try
        tarball = download(url)
        path = PATH.project(m, configs.sysimg.path)
        unpack(tarball, path)
        # NOTE: sysimg won't be shared, so we can just remove it
        isfile(tarball) && rm(tarball)
    catch e
        @warn "fail to download $url, building the system image locally"
        # force incremental build
        build_sysimg(m, configs; incremental = true, filter_stdlibs = false, cpu_target = "native")
    end
    return
end

function build_completion(m::Module, configs::Configurations.Comonicon)
    completion_dir = PATH.project(m, configs.application.path, configs.name, "completions")
    if !ispath(completion_dir)
        @info "creating path: $completion_dir"
        mkpath(completion_dir)
    end

    for sh in ["zsh"]
        script = completion_script(sh, m)
        script === nothing && continue
        write(joinpath(completion_dir, "$sh.completion"), script)
    end
    return
end

function sysimg_url(mod::Module, configs::Configurations.Comonicon)
    name = configs.name
    host = configs.download.host

    if host == "github.com"
        url =
            "https://github.com/" *
            configs.download.user *
            "/" *
            configs.download.repo *
            "/releases/download/"
    else
        error("host $host is not supported, please open an issue at $COMONICON_URL")
    end

    tarball = tarball_name(mod, name)
    url *= "v$(Comonicon.get_version(mod))/$tarball"
    return url
end


function tarball_name(m::Module, name::String; application::Bool = false)
    if application
        return "$name-application-$(get_version(m))-$(osname())-$(Sys.ARCH).tar.gz"
    else
        return "$name-sysimg-$(get_version(m))-julia-$VERSION-$(osname())-$(Sys.ARCH).tar.gz"
    end
end

"""
    osname()

Return the name of OS, will be used in building tarball.
"""
function osname()
    return Sys.isapple() ? "darwin" :
           Sys.islinux() ? "linux" :
           error("unsupported OS, please open an issue to request support at $COMONICON_URL")
end

"""
    cmd_script(mod, shadow; kwargs...)

Generates a shell script that can be use as the entry of
`mod.command_main`.

# Arguments

- `mod`: a module that contains the commands and the entry.
- `shadow`: location of a Julia script that calls the actual `mod.command_main`.

# Keywords

- `exename`: The julia executable name, default is [`PATH.default_exename`](@ref).
- `sysimg`: System image to use, default is `nothing`.
- `project`: the project path of the CLI.
- `compile`: julia compile level, can be [:yes, :no, :all, :min]
- `optimize`: julia optimization level, default is 2.
"""
function cmd_script(
    mod::Module,
    shadow::String;
    project::String = PATH.project(mod),
    exename::String = PATH.default_exename(),
    sysimg = nothing,
    compile = nothing,
    optimize = 2,
)

    head = "#!/bin/sh\n"
    if (project !== nothing) && ispath(project)
        head *= "JULIA_PROJECT=$project "
    end
    head *= exename
    script = String[head]

    if sysimg !== nothing
        push!(script, "-J$sysimg")
    end

    if compile in [:yes, :no, :all, :min]
        push!(script, "--compile=$compile")
    end

    push!(script, "-O$optimize")
    push!(script, "--startup-file=no")
    push!(script, "-- $shadow \$@")

    return join(script, " \\\n    ")
end

function completion_script(sh::String, m::Module)
    isdefined(m, :CASTED_COMMANDS) || error("cannot find Comonicon CLI entry")
    haskey(m.CASTED_COMMANDS, "main") || error("cannot find Comonicon CLI entry")
    main = m.CASTED_COMMANDS["main"]

    if sh == "zsh"
        return CodeGen.codegen(ZSHCompletionCtx(), main)
    else
        @warn(
            "$sh autocompletion is not supported, " *
            "please open an issue at $COMONICON_URL for feature request."
        )
    end
    return
end

Base.write(x::EntryCommand) = write(cachefile(), x)

"""
    write([io], cmd::EntryCommand)

Write the generated CLI script into a Julia script file. Default is the [`cachefile`](@ref).
"""
function Base.write(io::IO, x::EntryCommand)
    println(io, "#= generated by Comonicon =#")
    println(io, prettify(codegen(x)))
    println(io, "command_main()")
end

"""
    detect_shell()

Detect shell type via `SHELL` environment variable.
"""
function detect_shell()
    haskey(ENV, "SHELL") || error("cannot find available shell command")
    return basename(ENV["SHELL"])
end

function contain_comonicon_path(rcfile, env = ENV)
    if !haskey(env, "PATH")
        _contain_path(rcfile) && return true
        return false
    end

    for each in split(env["PATH"], ":")
        each == PATH.default_julia_bin() && return true
    end
    return false
end

function contain_comonicon_fpath(rcfile, env = ENV)
    if !haskey(env, "FPATH")
        _contain_fpath(rcfile) && return true
        return false
    end

    for each in split(env["FPATH"], ":")
        each == PATH.default_julia_fpath() && return true
    end
    return false
end

function _contain_path(rcfile)
    for line in readlines(rcfile)
        if strip(line) == "export PATH=\"\$HOME/.julia/bin:\$PATH\"" ||
           strip(line) == "export PATH=\"$(PATH.default_julia_bin()):\$PATH\""
            return true
        end
    end
    return false
end

function _contain_fpath(rcfile)
    for line in readlines(rcfile)
        if strip(line) == "export FPATH=\$HOME/.julia/completions:\$FPATH" ||
           strip(line) == "export FPATH=\"$(PATH.default_julia_fpath()):\$FPATH\""
            return true
        end
    end
    return false
end

function install_env_path(; yes::Bool = false)
    shell = detect_shell()

    config_file = ""
    if shell == "zsh"
        config_file = joinpath((haskey(ENV, "ZDOTDIR") ? ENV["ZDOTDIR"] : homedir()), ".zshrc")
    elseif shell == "bash"
        config_file = joinpath(homedir(), ".bashrc")
    else
        @warn "auto installation for $shell is not supported, please open an issue under Comonicon.jl"
    end

    write_path(joinpath(homedir(), config_file), yes)
end

"""
    write_path(rcfile[, yes=false])

Write `PATH` and `FPATH` to current shell's rc files (.zshrc, .bashrc)
if they do not exists.
"""
function write_path(rcfile, yes::Bool = false, env = ENV)
    isempty(rcfile) && return

    script = []
    msg = "cannot detect $(PATH.default_julia_bin()) in PATH, do you want to add it in PATH?"

    if !contain_comonicon_path(rcfile, env) && Tools.prompt(msg, yes)
        push!(
            script,
            """
            # generated by Comonicon
            # Julia bin PATH
            export PATH="$(PATH.default_julia_bin()):\$PATH"
            """,
        )
        @info "adding PATH to $rcfile"
    end

    msg = "cannot detect $(PATH.default_julia_fpath()) in FPATH, do you want to add it in FPATH?"
    if !contain_comonicon_fpath(rcfile, env) && Tools.prompt(msg, yes)
        push!(
            script,
            """
            # generated by Comonicon
            # Julia autocompletion PATH
            export FPATH="$(PATH.default_julia_fpath()):\$FPATH"
            autoload -Uz compinit && compinit
            """,
        )
        @info "adding FPATH to $rcfile"
    end

    # exit if nothing to add
    isempty(script) && return
    # NOTE: we don't create the file if not exists
    open(rcfile, "a") do io
        write(io, "\n" * join(script, "\n"))
    end
    @info "open a new terminal, or source $rcfile to enable the new PATH."
    return
end


end # BuildTools
