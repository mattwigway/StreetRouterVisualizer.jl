# Show a topological view of part of the graph

function topological_view(state, vertices, main_window)
    @info "showing topology for $(length(vertices)) vertices"
    topo_window = Window("Topological view")
    main_layout = Box(:v)
    push!(topo_window, main_layout)
    # force canvas to fill
    hlayout = Box(:h)
    push!(main_layout, hlayout)
    canvas = Canvas()
    push!(hlayout, canvas)
    set_gtk_property!(hlayout, :expand, canvas, true)
    set_gtk_property!(main_layout, :expand, hlayout, true)

    # Create an adjacency matrix
    adj = zeros(Bool, (length(vertices), length(vertices)))
    for (i, vertex) in enumerate(vertices)
        for nbr in outneighbors(state.graph.graph, vertex)
            if nbr ∈ vertices
                adj[i, findfirst(vertices .== nbr)] = true
            end
        end
    end

    pos = sfdp(adj)

    # now, draw
    @guarded draw(canvas) do canvas
        ctx = getgc(canvas)
        h = height(canvas)
        w = width(canvas)
        colidx = 1

        drawing = Drawing(w, h)
        background("white")
        sethue("black")
        setline(1)

        minx = Inf
        maxx = -Inf
        miny = Inf
        maxy = -Inf

        for p in pos
            minx = min(minx, p[1])
            maxx = max(maxx, p[1])
            miny = min(miny, p[2])
            maxy = max(maxy, p[2])
        end

        # set the scale appropriately
        Luxor.scale(w / ((maxx - minx) * 1.2), h / ((maxy - miny) * 1.2))
        Luxor.translate(-minx + (maxx - minx) * 0.1, -miny + (maxy - miny) * 0.1)
        # Luxor.scale(w / (maxx - minx), h / (maxy - miny))
        # Luxor.translate(-minx, -miny)

        @info "bbox" minx miny maxx maxy

        for (v, p) in zip(vertices, pos)
            sethue(hue_for_restriction(v))
            Luxor.circle(p[1], p[2], 0.01, :fill)
            for nbr in outneighbors(state.graph.graph, v)
                if nbr ∈ vertices
                    dest = pos[findfirst(vertices .== nbr)]
                    p1, p2 = Luxor.Point(p[1], p[2]), Luxor.Point(dest[1], dest[2])
                    Luxor.line(p1, p2, :stroke)
                    # make an arrow head, because luxor.arrow not working
                    backpt = Luxor.between(p1, p2, max(1 - 0.03 / distance(p1, p2), 0.05))
                    off = Luxor.perpendicular(backpt, p2, 0.01)
                    off2 = Luxor.perpendicular(backpt, p1, 0.01)
                    Luxor.newpath()
                    Luxor.move(p2)
                    Luxor.line(off)
                    Luxor.line(off2)
                    Luxor.line(p2)
                    Luxor.fillpath()
                    Luxor.newpath()
                end
            end
            fontsize(0.04)
            Luxor.text("$v", p[1], p[2])
        end

        # paint onto canvas
        # https://github.com/nodrygo/GtkLuxorNaiveDem
        Cairo.set_source_surface(ctx, drawing.surface)
        Cairo.paint(ctx)
    end

    showall(topo_window)
end