function tdvp_iteration(solver, PH, psi0::MPS, time_step::Number, sweeps::Sweeps; kwargs...)
  if length(psi0) == 1
    error(
      "`tdvp` currently does not support system sizes of 1. You can diagonalize the MPO tensor directly with tools like `LinearAlgebra.eigen`, `KrylovKit.exponentiate`, etc.",
    )
  end

  nsite::Int = get(kwargs, :nsite, 2)
  reverse_step::Bool = get(kwargs, :reverse_step, true)
  normalize::Bool = get(kwargs, :normalize, false)
  outputlevel::Int = get(kwargs, :outputlevel, 0)
  which_decomp::Union{String,Nothing} = get(kwargs, :which_decomp, nothing)
  svd_alg::String = get(kwargs, :svd_alg, "divide_and_conquer")
  obs = get(kwargs, :observer, NoObserver())

  write_when_maxdim_exceeds::Union{Int,Nothing} = get(
    kwargs, :write_when_maxdim_exceeds, nothing
  )

  psi = copy(psi0)
  N = length(psi)

  if !isortho(psi) || orthocenter(psi) != 1
    orthogonalize!(psi, 1)
  end
  @assert isortho(psi) && orthocenter(psi) == 1

  @timeit NDTensors.timer "tdvp: initial position!" begin
  position!(PH, psi, 1)
  end

  #@show time_step
  #@show nsweep(sweeps)
  #@show time_step/nsweep(sweeps)

  for sw in 1:nsweep(sweeps)
    sw_time = @elapsed begin
      maxtruncerr = 0.0

      if !isnothing(write_when_maxdim_exceeds) &&
        maxdim(sweeps, sw) > write_when_maxdim_exceeds
        if outputlevel >= 2
          println(
            "write_when_maxdim_exceeds = $write_when_maxdim_exceeds and maxdim(sweeps, sw) = $(maxdim(sweeps, sw)), writing environment tensors to disk",
          )
        end
        PH = disk(PH)
      end

      for (b, ha) in sweepnext(N; ncenter=nsite)
        PH.nsite = nsite
        @timeit NDTensors.timer "tdvp: position!" begin
        position!(PH, psi, b)
        end

        if nsite == 1
          phi1 = psi[b]
        elseif nsite == 2
          phi1 = psi[b] * psi[b + 1]
        end

        @timeit NDTensors.timer "tdvp: forward solver" begin
        phi1, info = solver(PH, time_step / 2, phi1)

        #if ha==1 && b==div(N,2)
        #  println("Solver info for ha==1, b==$b:")
        #  println(info)
        #end

        end

        ## if info.converged == 0
        ##   println("exponentiate not converged (b,ha)=($b,$ha)")
        ##   ITensors.pause()
        ## end

        normalize && (phi1 /= norm(phi1))

        spec = nothing
        if nsite == 1
          psi[b] = phi1
        elseif nsite == 2
          ortho = ha == 1 ? "left" : "right"

          drho = nothing
          if noise(sweeps, sw) > 0.0 && ha == 1
            drho = noise(sweeps, sw) * noiseterm(PH, phi, ortho)
          end

        @timeit NDTensors.timer "tdvp: replacebond" begin
          spec = replacebond!(
            psi,
            b,
            phi1;
            maxdim=maxdim(sweeps, sw),
            mindim=mindim(sweeps, sw),
            cutoff=cutoff(sweeps, sw),
            eigen_perturbation=drho,
            ortho=ortho,
            normalize,
            which_decomp,
            svd_alg,
          )
        end
          maxtruncerr = max(maxtruncerr, spec.truncerr)
        end

        #
        # Do backwards evolution step
        #
        if reverse_step && (ha == 1 && (b + nsite - 1 != N)) || (ha == 2 && b != 1)
          b1 = (ha == 1 ? b + 1 : b)
          Δ = (ha == 1 ? +1 : -1)
          if nsite == 2
            phi0 = psi[b1]
          elseif nsite == 1
            uinds = uniqueinds(phi1, psi[b + Δ])
            U, S, V = svd(phi1, uinds)
            psi[b] = U
            phi0 = S * V
          end

          PH.nsite = nsite - 1
          position!(PH, psi, b1)

          @timeit NDTensors.timer "tdvp: backwards solver" begin
          phi0, info = solver(PH, -time_step / 2, phi0)
          end

          normalize && (phi0 ./= norm(phi0))

          if nsite == 2
            psi[b1] = phi0
          elseif nsite == 1
            psi[b + Δ] = phi0 * psi[b + Δ]
          end
          PH.nsite = nsite
        end

        if outputlevel >= 2
          @printf("Sweep %d, half %d, bond (%d,%d) \n", sw, ha, b, b + 1)
          @printf(
            "  Truncated using cutoff=%.1E maxdim=%d mindim=%d\n",
            cutoff(sweeps, sw),
            maxdim(sweeps, sw),
            mindim(sweeps, sw)
          )
          @printf(
            "  Trunc. err=%.2E, bond dimension %d\n", spec.truncerr, dim(linkind(psi, b))
          )
          flush(stdout)
        end

        sweep_is_done = (b == 1 && ha == 2)
        measure!(
          obs; psi, bond=b, sweep=sw, half_sweep=ha, spec, outputlevel, sweep_is_done
        )
      end
    end #@elapsed for sw_time

    if outputlevel >= 1
      @printf(
        "After sweep %d maxlinkdim=%d maxerr=%.2E time=%.3f\n",
        sw,
        maxlinkdim(psi),
        maxtruncerr,
        sw_time
      )
      flush(stdout)
    end
    isdone = checkdone!(obs; psi, sweep=sw, outputlevel)

    isdone && break
  end

  # Just to be sure:
  normalize && normalize!(psi)

  return psi, PH
end

function exponentiate_solver(; kwargs...)
  solver_kwargs = (;
    ishermitian=get(kwargs, :ishermitian, true),
    issymmetric=get(kwargs, :issymmetric, true),
    tol=get(kwargs, :exponentiate_tol, 1E-12),
    krylovdim=get(kwargs, :exponentiate_krylovdim, 30),
    maxiter=get(kwargs, :exponentiate_maxiter, 100),
    verbosity=get(kwargs, :exponentiate_verbosity, 0),
    eager=true,
  )
  function solver(H, t, psi0; kws...)
    psi, info = exponentiate(H, t, psi0; solver_kwargs..., kws...)
    return psi, info
  end
  return solver
end

function applyexp_solver(; kwargs...)
  solver_kwargs = (;
    tol=get(kwargs, :exponentiate_tol, 1E-12),
    maxiter=get(kwargs, :exponentiate_krylovdim, 30),
    outputlevel=get(kwargs, :exponentiate_verbosity, 0),
  )
  function solver(H, t, psi0; kws...)
    psi, info = apply_exp(H, t, psi0; solver_kwargs..., kws...)
    return psi, info
  end
  return solver
end

function default_tdvp_solver(; kwargs...)
  return applyexp_solver(; kwargs...)
end

function eigsolve_solver(; kwargs...)
  howmany = 1
  which = get(kwargs, :eigsolve_which_eigenvalue, :SR)
  solver_kwargs = (;
    ishermitian=get(kwargs, :ishermitian, true),
    tol=get(kwargs, :eigsolve_tol, 1E-14),
    krylovdim=get(kwargs, :eigsolve_krylovdim, 3),
    maxiter=get(kwargs, :eigsolve_maxiter, 1),
    verbosity=get(kwargs, :eigsolve_verbosity, 0),
  )
  function solver(H, t, psi0; kws...)
    vals, vecs, info = eigsolve(H, psi0, howmany, which; solver_kwargs..., kws...)
    psi = vecs[1]
    return psi, info
  end
  return solver
end

function _tdvp_compute_sweeps(t; kwargs...)
  time_step::Number = get(kwargs, :time_step, t)
  nsweeps::Integer = get(kwargs, :nsweeps, 0)

  if nsweeps > 0 && time_step != t
    error("Cannot specify both time_step and nsweeps in tdvp")
  elseif isfinite(time_step) && abs(time_step) > 0.0 && nsweeps == 0
    nsweeps = convert(Int, ceil(abs(t / time_step)))
    if !(nsweeps * time_step ≈ t)
      error("Time step $time_step not commensurate with total time t=$t")
    end
  end

  return Sweeps(
    nsweeps;
    maxdim=get(kwargs, :maxdim, typemax(Int)),
    mindim=get(kwargs, :mindim, 1),
    cutoff=get(kwargs, :cutoff, 1E-8),
    noise=get(kwargs, :noise, 0.0),
  )
end

function tdvp(solver, H, psi0::MPS, t::Number, sweeps::Sweeps=Sweeps(); kwargs...)
  reverse_step = true
  isempty(sweeps) && (sweeps = _tdvp_compute_sweeps(t; kwargs...))
  time_step::Number = get(kwargs, :time_step, t)
  psi, _ = tdvp_iteration(solver, H, psi0, time_step, sweeps; reverse_step, kwargs...)
  return psi
end

function tdvp(H, psi0::MPS, t::Number, sweeps::Sweeps=Sweeps(); kwargs...)
  return tdvp(default_tdvp_solver(;kwargs...), H, psi0, t, sweeps; kwargs...)
end

function dmrg(H, psi0::MPS, sweeps::Sweeps=Sweeps(); kwargs...)
  t = Inf # DMRG is TDVP with an infinite timestep and no reverse step
  isempty(sweeps) && (sweeps = _tdvp_compute_sweeps(t; kwargs...))
  reverse_step = false
  psi, _ = tdvp_iteration(eigsolve_solver(;kwargs...), H, psi0, t, sweeps; reverse_step, kwargs...)
  return psi
end

function dmrg(H::MPO, psi0::MPS, sweeps::Sweeps=Sweeps(); kwargs...)
  check_hascommoninds(siteinds, H, psi0)
  check_hascommoninds(siteinds, H, psi0')
  # Permute the indices to have a better memory layout
  # and minimize permutations
  H = ITensors.permute(H, (linkind, siteinds, linkind))
  PH = ProjMPO(H)
  return dmrg(PH, psi0, sweeps; kwargs...)
end

"""
    tdvp(Hs::Vector{MPO},psi0::MPS,t::Number; kwargs...)
    tdvp(Hs::Vector{MPO},psi0::MPS,t::Number, sweeps::Sweeps; kwargs...)

Use the time dependent variational principle (TDVP) algorithm
to compute `exp(t*H)*psi0` using an efficient algorithm based
on alternating optimization of the MPS tensors and local Krylov
exponentiation of H.
                    
This version of `tdvp` accepts a representation of H as a
Vector of MPOs, Hs = [H1,H2,H3,...] such that H is defined
as H = H1+H2+H3+...
Note that this sum of MPOs is not actually computed; rather
the set of MPOs [H1,H2,H3,..] is efficiently looped over at 
each step of the algorithm when optimizing the MPS.

Returns:
* `psi::MPS` - time-evolved MPS
"""
function tdvp(
  solver, Hs::Vector{MPO}, psi0::MPS, t::Number, sweeps::Sweeps=Sweeps(); kwargs...
)
  for H in Hs
    check_hascommoninds(siteinds, H, psi0)
    check_hascommoninds(siteinds, H, psi0')
  end
  Hs .= ITensors.permute.(Hs, Ref((linkind, siteinds, linkind)))
  PHs = ProjMPOSum(Hs)
  return tdvp(solver, PHs, psi0, t, sweeps; kwargs...)
end

function tdvp(H::Vector{MPO}, psi0::MPS, t::Number, sweeps::Sweeps=Sweeps(); kwargs...)
  return tdvp(default_tdvp_solver(;kwargs...), H, psi0, t, sweeps; kwargs...)
end

"""
    tdvp(H::MPO,psi0::MPS,t::Number; kwargs...)
    tdvp(H::MPO,psi0::MPS,t::Number,sweeps::Sweeps; kwargs...)

Use the time dependent variational principle (TDVP) algorithm
to compute `exp(t*H)*psi0` using an efficient algorithm based
on alternating optimization of the MPS tensors and local Krylov
exponentiation of H.
                    
Returns:
* `psi::MPS` - time-evolved MPS

Optional keyword arguments:
* `outputlevel::Int = 1` - larger outputlevel values resulting in printing more information and 0 means no output
* `observer` - object implementing the [Observer](@ref observer) interface which can perform measurements and stop early
* `write_when_maxdim_exceeds::Int` - when the allowed maxdim exceeds this value, begin saving tensors to disk to free memory in large calculations
"""
function tdvp(solver, H::MPO, psi0::MPS, t::Number, sweeps::Sweeps=Sweeps(); kwargs...)
  check_hascommoninds(siteinds, H, psi0)
  check_hascommoninds(siteinds, H, psi0')
  # Permute the indices to have a better memory layout
  # and minimize permutations
  H = ITensors.permute(H, (linkind, siteinds, linkind))
  PH = ProjMPO(H)
  return tdvp(solver, PH, psi0, t, sweeps; kwargs...)
end

function tdvp(H::MPO, psi0::MPS, t::Number, sweeps::Sweeps=Sweeps(); kwargs...)
  return tdvp(default_tdvp_solver(;kwargs...), H, psi0, t, sweeps; kwargs...)
  #return tdvp(exponentiate_solver(;kwargs...), H, psi0, t, sweeps; kwargs...)
end
