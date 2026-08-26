# Regional FCAS prices from `TermConstraint` duals - a pure read-side function over solved
# results, not part of `construct_service!`. Column names match `read_fcas_prices` (`SETTLEMENTDATE`
# not `DateTime`, `BIDTYPE` not `service`) so a caller can compare the two directly.

"""
    compute_fcas_prices(results::PSI.OptimizationProblemResults, sys::PSY.System) -> DataFrame

Each `(region, service)` pair's FCAS price, in \$/MW, as the sum of `NEMConstraintLimit` duals of
every [`GenericConstraint`](@ref) whose `fcas_requirements` names that pair (`GenericConstraint`'s
own docstring: a pair's price can be governed by several constraints at once). Returns
`SETTLEMENTDATE`/`REGIONID`/`BIDTYPE`/`RRP` - the same names [`read_fcas_prices`](@ref) uses, so a
caller can compare a solve's prices against AEMO's published ones directly, though an exact match
isn't expected: this package's solver dispatch doesn't replicate NEMDE's.

`add_constraints!` builds `NEMConstraintLimit` with both sides in per-unit (`expr[name,t] <sense>
rhs_refs[t] / base_power`), so its raw dual is \$ per unit of per-unit RHS, i.e. \$ per
`base_power` MW - divided by `PSI.get_model_base_power(results)` here to get \$/MW, matching
`RRP`'s units.

A `GenericConstraint` whose dual was never registered (its `ServiceModel` didn't request
`duals = [NEMConstraintLimit]`, or [`TermConstraint`](@ref) skipped it whole - see that type's
module comment) contributes nothing to any `(region, service)` pair it would have fed, rather
than raising: a partial sum is no more meaningful than a missing one, and a region/service with no
contributing dual at all is simply absent from the returned frame.
"""
function compute_fcas_prices(results::PSI.OptimizationProblemResults, sys::PSY.System)
    base_power = PSI.get_model_base_power(results)
    dual_names = Set(PSI.list_dual_names(results))

    requirements = Dict{Tuple{String, BidType}, Vector{String}}()
    for gc in PSY.get_components(GenericConstraint, sys)
        for req in get_fcas_requirements(gc)
            key = (get_region(req), get_service(req))
            push!(get!(requirements, key, String[]), PSY.get_name(gc))
        end
    end

    out = DataFrame(SETTLEMENTDATE = Dates.DateTime[], REGIONID = String[], BIDTYPE = BidType[], RRP = Float64[])
    for ((region, service), gencon_ids) in requirements
        totals = Dict{Dates.DateTime, Float64}()
        for gencon_id in gencon_ids
            dual_name = "NEMConstraintLimit__GenericConstraint__$(gencon_id)"
            dual_name in dual_names || continue
            for row in eachrow(PSI.read_dual(results, dual_name))
                totals[row.DateTime] = get(totals, row.DateTime, 0.0) + row.value / base_power
            end
        end
        isempty(totals) && continue
        for dt in sort(collect(keys(totals)))
            push!(out, (dt, region, service, totals[dt]))
        end
    end
    return out
end
