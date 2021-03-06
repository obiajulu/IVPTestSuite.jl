################
#@require Sundials begin
import Sundials

# note that using a Jacobian is messy in Sundials

# Monkey-patch Sundials v0.2
# TODO: remove this after a new Sundials.jl version gets tagged
eval(Sundials, quote
macro checkflag(ex)
    # Insert a check that the given function call returns 0,
    # throw an error otherwise. Only apply directly to function calls.
    @assert Base.Meta.isexpr(ex, :call)
    fname = ex.args[1]
    quote
        flag = $(esc(ex))
        if flag != 0
            error($(string(fname, " failed with error code = ")), flag)
        end
        flag
    end
end
end)


extraoutputs = 10^6
const sundialssolvers = Dict{Any,Solver}()


# CVode wrapper to high level interface: Sundials.cvode
#####

function wrapper_CVODE_simple{N,T}(tr::TestRun{N,T})
    # Wraps the specific MyPkg.mysolver such that it works within
    # IVPTestSuite setup.
    tc = tr.tc
    so = tr.solver
    ###
    # 0) Wrap tc.fn!, tc.jac!, tc.mass! if necessary
    # not necessary
    ###
    # 1) Make call signature

    tsteps = collect(linspace(tc.tspan[1], tc.tspan[2], extraoutputs)) # TODO: fix by setting mxstep higher
    args = (tc.fn!, tc.ic, tsteps)
    kwargs  = ((:reltol, tr.reltol), (:abstol, tr.abstol))

    ###
    # 2) Call solver, if it does not succeed throw an error (if that
    # is not done anyway)
    out = so.solverfn(args...; kwargs...)
    # (probably no need to modify this section)

    ###
    # 3) Transform output to conform to standard:
    # tend -- end time reached
    # yend -- solution at tend
    # stats -- statistics, if available: (steps_total,steps_accepted, fn_evals, jac_evals, linear_solves)
    #                         otherwise  (-1, -1, -1, -1, -1)
    tend = tc.tspan[2]
    yend = squeeze(out[end,:],1)
    stats = (-1, -1, -1, -1, -1)
    return tend, yend, stats
end
daeindex = 0
adaptive = true
cvode_simple = Solver{:im}(Sundials.cvode, Sundials, wrapper_CVODE_simple, stiff, adaptive, daeindex, explicit_eq)
sundialssolvers[Sundials.cvode] = cvode_simple

# CVode wrapper to low level interface: Sundials.CVode
#####

# Note that this function cannot be nested inside wrapper_CVODE
function cvodefun(t::Float64, y::Sundials.N_Vector, yp::Sundials.N_Vector, fn!::Function)
    y = Sundials.asarray(y)
    yp = Sundials.asarray(yp)
    fn!(t, y, yp)
    return Int32(0)
end

function wrapper_CVODE{N,T}(tr::TestRun{N,T})
    # Adapted from the Sundials.jl wrapper

    # Wraps the specific MyPkg.mysolver such that it works within
    # IVPTestSuite setup.
    tc = tr.tc
    so = tr.solver
    ###
    # 0) Wrap tc.fn!, tc.jac!, tc.mass! if necessary
    # not necessary


    ###
    # 1) Make call signature

    mem = Sundials.CVodeCreate(Sundials.CV_BDF, Sundials.CV_NEWTON)
    if mem == C_NULL
        error("Failed to allocate CVODE solver object")
    end

    flag = Sundials.@checkflag Sundials.CVodeInit(mem,
                              cfunction(cvodefun, Int32, (Sundials.realtype, Sundials.N_Vector, Sundials.N_Vector, Ref{Function})),
                              tc.tspan[1], Sundials.nvector(tc.ic))
    flag = Sundials.@checkflag Sundials.CVodeSetUserData(mem, tc.fn!)
    flag = Sundials.@checkflag Sundials.CVodeSStolerances(mem, tr.reltol, tr.abstol)
    flag = Sundials.@checkflag Sundials.CVodeSetMaxNumSteps(mem, -1)
    flag = Sundials.@checkflag Sundials.CVDense(mem, tc.dof)
    y = copy(tc.ic)
    tout = [0.0]

    ###
    # 2) Call solver, if it does not succeed throw an error (if that
    # is not done anyway)
    for k in 2:length(tc.tspan)
        flag = so.solverfn(mem, tc.tspan[k], y, tout, Sundials.CV_NORMAL) # solverfn==CVode
    end

    ###
    # 3) Transform output to conform to standard:
    # tend -- end time reached
    # yend -- solution at tend
    # stats -- statistics, if available: (steps_total,steps_accepted, fn_evals, jac_evals, linear_solves)
    #                         otherwise  (-1, -1, -1, -1, -1)
    tend = tout[1]
    yend = y
    stats = (-1, -1, -1, -1, -1) # TODO
    return tend, yend, stats
end
daeindex = 0
adaptive = true
cvode = Solver{:im}(Sundials.CVode, Sundials, wrapper_CVODE, stiff, adaptive, daeindex, explicit_eq)
sundialssolvers[Sundials.CVode] = cvode


# IDA wrapper to high-level interface: Sundials.idasol
#####

function wrapper_IDA_simple{N,T}(tr::TestRun{N,T})
    # Wraps the specific MyPkg.mysolver such that it works within
    # IVPTestSuite setup.
    tc = tr.tc
    so = tr.solver
    ###
    # 0) Wrap tc.fn!, tc.jac!, tc.mass! if necessary

    if hasmass(tc)
        function residual!(t, y, dydt, res)
            m = tc.mass!()
            tc.mass!(t,y,m)
            tc.fn!(t,y,res)
            res[:] = res-m*dydt
        end
    else
        function residual!(t, y, dydt, res)
            tc.fn!(t,y,res)
            res[:] = res-dydt
        end
    end

    ###
    # 1) Make call signature
    ic_dydt = tc.fn!()
    tc.fn!(tc.tspan[1], tc.ic, ic_dydt)
    tsteps = collect(linspace(tc.tspan[1], tc.tspan[2], extraoutputs)) # TODO: fix by setting mxstep higher
    args = (residual!, tc.ic, ic_dydt, tsteps)
    kwargs  = ((:reltol, tr.reltol), (:abstol, tr.abstol))

    ###
    # 2) Call solver, if it does not succeed throw an error (if that
    # is not done anyway)
    y,dydt = so.solverfn(args...; kwargs...)
    # (probably no need to modify this section)

    ###
    # 3) Transform output to conform to standard:
    # tend -- end time reached
    # yend -- solution at tend
    # stats -- statistics, if available: (steps_total,steps_accepted, fn_evals, jac_evals, linear_solves)
    #                         otherwise  (-1, -1, -1, -1, -1)
    tend = tc.tspan[2]
    yend = squeeze(y[end,:],1)
    stats = (-1, -1, -1, -1, -1)
    return tend, yend, stats
end
daeindex = 1
adaptive = true
ida_simple = Solver{:im}(Sundials.idasol, Sundials, wrapper_IDA_simple, stiff, adaptive, daeindex, implicit_eq)
sundialssolvers[Sundials.idasol] = ida_simple

# IDA wrapper to low-level interface: Sundials.ISASolve
#####

function idasolfun(t::Float64, y::Sundials.N_Vector, yp::Sundials.N_Vector, r::Sundials.N_Vector, userfun::Function)
    y = Sundials.asarray(y)
    yp = Sundials.asarray(yp)
    r = Sundials.asarray(r)
    userfun(t, y, yp, r)
    return Int32(0)   # indicates normal return
end

function wrapper_IDA{N,T}(tr::TestRun{N,T})
    # Adapted from the Sundials.jl wrapper

    # Wraps the specific MyPkg.mysolver such that it works within
    # IVPTestSuite setup.
    tc = tr.tc
    so = tr.solver
    ###
    # 0) Wrap tc.fn!, tc.jac!, tc.mass! if necessary
    if hasmass(tc)
        function residual!(t, y, dydt, res)
            m = tc.mass!()
            tc.mass!(t,y,m)
            tc.fn!(t,y,res)
            res[:] = res-m*dydt
        end
    else
        function residual!(t, y, dydt, res)
            tc.fn!(t,y,res)
            res[:] = res-dydt
        end
    end

    ###
    # 1) Make call signature
    ic_dydt = tc.fn!()
    tc.fn!(tc.tspan[1], tc.ic, ic_dydt)

    mem = Sundials.IDACreate()
    if mem == C_NULL
        error("Failed to allocate CVODE solver object")
    end

    flag = Sundials.@checkflag Sundials.IDAInit(mem, cfunction(idasolfun, Int32, (Sundials.realtype, Sundials.N_Vector, Sundials.N_Vector, Sundials.N_Vector, Ref{Function})),
                            tc.tspan[1], Sundials.nvector(tc.ic), Sundials.nvector(ic_dydt))
    flag = Sundials.@checkflag Sundials.IDASetUserData(mem, residual!)
    flag = Sundials.@checkflag Sundials.IDASStolerances(mem, tr.reltol, tr.abstol)
    flag = Sundials.@checkflag Sundials.IDADense(mem, tc.dof)
    flag = Sundials.@checkflag Sundials.IDASetMaxNumSteps(mem, -1)

    rtest = zeros(T, tc.dof)
    residual!(tc.tspan[1], tc.ic, ic_dydt, rtest)
    if any(abs(rtest) .>= tr.reltol)
        error("Inconsistent ICs!  This shouldn't happen...")
    end
    yres = zeros(T,length(tc.tspan), length(tc.ic))
    ypres = zeros(T,length(tc.tspan), length(tc.ic))
    yres[1,:] = tc.ic
    ypres[1,:] = ic_dydt
    y = copy(tc.ic)
    yp = copy(ic_dydt)
    tout = [0.0]

    ###
    # 2) Call solver, if it does not succeed throw an error (if that
    # is not done anyway)
    for k in 2:length(tc.tspan)
        flag = so.solverfn(mem, tc.tspan[k], tout, y, yp, Sundials.IDA_NORMAL) # solverfn==IDASolve
    end

    ###
    # 3) Transform output to conform to standard:
    # tend  -- end time reached
    # yend  -- solution at tend
    # stats -- statistics, if available: (steps_total,steps_accepted, fn_evals, jac_evals, linear_solves)
    #                         otherwise  (-1, -1, -1, -1, -1)
    tend = tout[1]
    yend = y
    stats = (-1, -1, -1, -1, -1) # TODO
    return tend, yend, stats
end
daeindex = 1
adaptive = true
ida = Solver{:im}(Sundials.IDASolve, Sundials, wrapper_IDA, stiff, adaptive, daeindex, implicit_eq)

sundialssolvers[Sundials.IDASolve] = ida

merge!(allsolvers, sundialssolvers)
