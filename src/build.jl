module PATH
using Libdl
using ..Comonicon

project(m::Module, xs...) = joinpath(dirname(dirname(pathof(m))), xs...)
project(xs...) = project(Comonicon, xs...)

"""
    default_sysimg()

Return `libcomonicon.(dylib, so, dll)` if the package `Comonicon`
is compile by PackageCompiler. Or return `nothing`.
"""
function default_sysimg()
    lib = project("deps", "lib", "libcomonicon.$(Libdl.dlext)")
    if isfile(lib)
        return lib
    else
        return
    end
end

"""
    default_exename()

Default Julia executable name: `joinpath(Sys.BINDIR, Base.julia_exename())`
"""
default_exename() = joinpath(Sys.BINDIR, Base.julia_exename())

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
- `sysimg`: System image to use, default is [`PATH.default_sysimg`](@ref).
- `project`: the project path of the CLI.
- `compile`: julia compile level, can be [:yes, :no, :all, :min]
- `optimize`: julia optimization level, default is 2.
"""
function cmd_script(
    mod,
    shadow;
    exename = PATH.default_exename(),
    project = PATH.project(mod),
    sysimg = PATH.default_sysimg(),
    compile = nothing,
    optimize = 2,
)
    script = String["#!/bin/sh\nJULIA_PROJECT=$project $exename"]

    if sysimg !== nothing
        push!(script, "-J$sysimg")
    end

    if compile in [:yes, :no, :all, :min]
        push!(script, "--compile=$compile")
    end

    push!(script, "-O$optimize")
    push!(script, "-- $shadow \$@")

    return join(script, " \\\n    ")
end

"""
    precompile_script(mod)

Generates a script to execute as `precompile_execution_file` for all the commands.
"""
function precompile_script(mod::Module)
    script = "using $mod;\n$mod.command_main([\"-h\"]);\n"

    if isdefined(mod, :CASTED_COMMANDS)
        for (name, cmd) in mod.CASTED_COMMANDS
            if name != "main" # skip main command
                script *= "$mod.command_main([$(precompile_script(mod, cmd))]);\n"
            end
        end
    end
    return script
end

function precompile_script(mod, cmd::EntryCommand)
    return precompile_script(mod, cmd.root)
end

function precompile_script(mod, cmd::LeafCommand)
    return "\"$(cmd_name(cmd))\", \"-h\""
end

function precompile_script(mod, cmd::NodeCommand)
    return join(map(x -> "\"$(cmd_name(cmd))\", " * precompile_script(mod, x), cmd.subcmds))
end

"""
    install(mod[, name=default_name(mod)]; kwargs...)

Install the CLI defined in module `mod` to the `bin`.

# Arguments

- `mod`: module that contains the CLI, usually a project module.
- `name`: default is the [`default_name`](@ref).

# Keywords

- `bin`: path of the `bin` folder, default is the `~/.julia/bin`.
- `exename`: Julia executable name, default is [`PATH.default_exename`](@ref).
- `project`: the project path of the CLI.
- `compile`: julia compile level, can be [:yes, :no, :all, :min]
- `optimize`: julia optimization level, default is 2.
- `sysimg`: compile a system image using PackageCompiler or not, default is `false`.
- `incremental`: PackageCompiler option.
- `filter_stdlibs`: PackageCompiler option.
- `lib_path`: the `lib` folder that stores the compiled system image, default is the `<project>/deps/lib`.
"""
function install(
    mod::Module,
    name = default_name(mod);
    bin = joinpath(first(DEPOT_PATH), "bin"),
    exename = PATH.default_exename(),
    project = PATH.project(mod),
    sysimg::Bool = false,
    incremental::Bool = false,
    compile = nothing,
    filter_stdlibs = false,
    lib_path = PATH.project(mod, "deps", "lib"),
    optimize = 2,
)

    if sysimg
        if !ispath(lib_path)
            @info "creating library path: $lib_path"
            mkpath(lib_path)
        end

        precompile_jl = PATH.project(mod, "deps", "precompile.jl")
        @info "generating precompile execution file: $precompile_jl"
        open(precompile_jl, "w+") do f
            print(f, precompile_script(mod))
        end

        @info "compile under project: $project"
        @info "incremental: $incremental"
        @info "filter stdlibs: $filter_stdlibs"
        sysimg_path = PATH.project(mod, "deps", "lib", "lib$name.$(Libdl.dlext)")
        create_sysimage(
            nameof(mod);
            sysimage_path = sysimg_path,
            incremental = incremental,
            project = project,
            precompile_execution_file = precompile_jl,
            filter_stdlibs = filter_stdlibs,
        )
    else
        sysimg_path = nothing
    end

    shadow = joinpath(bin, name * ".jl")
    shell_script = cmd_script(
        mod,
        shadow;
        exename = exename,
        project = project,
        sysimg = sysimg_path,
        compile = compile,
        optimize = optimize,
    )

    file = joinpath(bin, name)

    if !ispath(bin)
        @info "cannot find Julia bin folder creating .julia/bin"
        mkpath(bin)
    end

    # generate contents
    @info "generating $shadow"
    open(shadow, "w+") do f
        println(f, "#= generated by Comonicon for $name =# using $mod; $mod.command_main()")
    end

    @info "generating $file"
    open(file, "w+") do f
        println(f, shell_script)
    end

    chmod(file, 0o777)
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
    build()

Build a system image for `Comonicon`.
"""
function build()
    if !ispath(project("deps", "lib"))
        mkpath(project("deps", "lib"))
    end

    create_sysimage(
        [:Comonicon, :Test];
        sysimage_path = project("deps", "lib", "libcomonicon.$(Libdl.dlext)"),
        project = project(),
        precompile_execution_file = project("test", "runtests.jl"),
    )
end
