function update_spt(state)
    if isnothing(state.spt) || isempty(state.spt)
        state.spt = Set{Int64}([state.origin])
    end

    @info "nbrs" outneighbors(state.graph.graph, 53626)

    for v in collect(state.spt)
        for nbr in outneighbors(state.graph.graph, v)
            push!(state.spt, nbr)
            while has_prop(state.graph.graph, nbr, :system_idx)
                # continue to the end of the turn
                push!(state.spt, nbr)
                outnbrs = outneighbors(state.graph.graph, nbr)
                @assert length(outnbrs) == 1
                nbr = outnbrs[1]
            end
        end
    end
end