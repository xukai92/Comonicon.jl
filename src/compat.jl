@static if VERSION < v"1.7"
    function Base.pkgdir(m::Module, path_::String, paths...)
        joinpath(pkgdir(m), path_, paths...)
    end
end

function _sprint(f, args...; color::Bool, displaysize = (24, 80), hint_width::Int = 10)
    buf = IOBuffer()
    io = IOContext(buf, :color => color, :displaysize => displaysize, :hint_width => hint_width)
    f(io, args...)
    return String(take!(buf))
end
