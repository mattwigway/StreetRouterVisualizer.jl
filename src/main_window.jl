function main()
    window = Window("StreetRouterVisualizer.jl")
    main_layout = Box(:v)
    push!(window, main_layout)
    toolbar = Box(:h)
    push!(main_layout, toolbar)

    # add toolbar buttons
    open_button = Button("Open")
    reload_button = Button("Reload")
    origin_button = Button("Set origin")
    dest_button = Button("Set destination")
    spt_step_button = Button("Step SPT")
    route_button = Button("Route")
    normal_button = Button("Normal view")
    turn_button = Button("Turn-based view")
    vertex_label_button = Button("Toggle vertex labels")
    color_by_turn_button = Button("Color by turn")
    color_by_system_button = Button("Color by turn system")
    color_by_strong_component_button = Button("Color by strong component")
    find_vertex_entry = GtkEntry()
    find_vertex_button = Button("Find vertex")
    topo_button = Button("Show topology")
    quit_button = Button("Quit")

    push!(toolbar, open_button)
    push!(toolbar, reload_button)
    push!(toolbar, origin_button)
    push!(toolbar, dest_button)
    push!(toolbar, spt_step_button)
    push!(toolbar, route_button)
    push!(toolbar, normal_button)
    push!(toolbar, turn_button)
    push!(toolbar, vertex_label_button)
    push!(toolbar, color_by_turn_button)
    push!(toolbar, color_by_system_button)
    push!(toolbar, color_by_strong_component_button)
    push!(toolbar, find_vertex_entry)
    push!(toolbar, find_vertex_button)
    push!(toolbar, topo_button)
    push!(toolbar, quit_button)

    canvas = Canvas()
    cbox = GtkBox(:h)
    # need to have it in an hbox to expand vertically: https://discourse.julialang.org/t/setting-size-of-gtkcanvas-and-other-widgets/14658/2
    push!(cbox, canvas)
    set_gtk_property!(cbox, :expand, canvas, true)
    push!(main_layout, cbox)
    set_gtk_property!(main_layout, :expand, cbox, true)

    status = GtkLabel("No graph")
    push!(main_layout, status)

    # Connect events to buttons
    exit_condition = Condition()

    # the viewing area extent is defined by the NE corner and the width in degrees; this way
    # resizing the window zooms the existing view
    state = VisualizerState(35.913, -79.057, 0.12, :pan, :turn, :normal, false, nothing, nothing, nothing, nothing, nothing, nothing, Set{Int64}())

    @guarded draw(canvas) do widget
        @info "Current state" state
        Revise.revise() # DEVELOPMENT: reload code on each draw
        if isnothing(state.graph)
            ctx = getgc(canvas)
            h = height(canvas)
            w = width(canvas)
            
            # just paint it white
            rectangle(ctx, 0, 0, w, h)
            set_source_rgb(ctx, 1, 1, 1)
            fill(ctx)
        else
            draw_graph(canvas, state)
            base_status = "|V|: $(nv(state.graph.graph))   |E|: $(ne(state.graph.graph))"
            if !isnothing(state.distance)
                base_status *= "    Route travel time: $(human_time(state.distance))"
            end
            GAccessor.text(status, base_status)
        end
    end

    signal_connect(x -> (state.clickmode = :origin), origin_button, :clicked)
    signal_connect(x -> (state.clickmode = :destination), dest_button, :clicked)
    signal_connect(route_button, :clicked) do e
        if !isnothing(state.origin) && !isnothing(state.destination)
            route!(state)
            draw(canvas)
        end
    end
    signal_connect(x -> begin
        state.view = :normal
        draw(canvas)
    end, normal_button, :clicked)
    signal_connect(x -> begin
        state.view = :turnbased
        draw(canvas)
    end, turn_button, :clicked)

    canvas.mouse.scroll = @guarded (wid, e) -> begin
        # figure out current extents
        _, east, south, _ = get_canvas_bbox(wid, state)

        # shrink or expand bbox around cursor
        # the point under the mouse should remain in exactly the same place
        # while everything else moves around it
        # how far across the screen the mouse is
        w = east - state.west
        h = state.north - south

        # figure out coordinates of scroll point
        scroll_lon = e.x / width(canvas) * w + state.west
        scroll_lat = e.y / height(canvas) * h + south


        frac_x = (scroll_lon - state.west) / w
        frac_y = (scroll_lat - south) / h

        # now, figure out the new bbox
        # figure out new height and width
        frac = if e.direction == Gtk.GdkScrollDirection.GDK_SCROLL_UP
            0.9
        elseif e.direction == Gtk.GdkScrollDirection.GDK_SCROLL_DOWN
            1.1
        else
            1
        end
        neww = w * frac
        newh = h * frac

        south = scroll_lat - newh * frac_y
        state.north = south + newh
        state.west = scroll_lon - neww * frac_x
        state.height_degrees = state.north - south

        draw(canvas)
    end

    # pan by dragging mouse
    panstart = nothing
    canvas.mouse.button1press = @guarded (wid, e) -> begin
        if state.clickmode == :pan
            _, east, south, _ = get_canvas_bbox(wid, state)
            w = east - state.west
            h = state.north - south
            e_lon = e.x / width(canvas) * w + state.west
            e_lat = e.y / height(canvas) * h + south
            panstart = (e_lon, e_lat)
        end
    end

    canvas.mouse.button1release = @guarded (wid, e) -> begin
        if state.clickmode == :pan && !isnothing(panstart)
            _, east, south, _ = get_canvas_bbox(wid, state)
            w = east - state.west
            h = state.north - south
            e_lon = e.x / width(canvas) * w + state.west
            e_lat = e.y / height(canvas) * h + south
            state.west -= e_lon - panstart[1]
            state.north += e_lat - panstart[2]
            panstart = nothing
        elseif state.clickmode == :origin
            state.origin = node_for_lonlat(lonlat_for_click(wid, e, state)..., state)
            state.clickmode = :pan
            empty!(state.spt)
        elseif state.clickmode == :destination
            state.destination = node_for_lonlat(lonlat_for_click(wid, e, state)..., state)
            state.clickmode = :pan
        end
        draw(canvas)
    end

    signal_connect(x -> notify(exit_condition), quit_button, :clicked)
    signal_connect(open_button, :clicked) do s
        file = open_dialog_native("Open graph", window, ("*",))
        set_gtk_property!(window, "title", "StreetRouterVisualizer.jl: $(basename(file))")
        state.graphpath = file
        state.graph = read_graph(file, window)

        # zoom so we can see it
        north = -Inf
        west = Inf
        south = Inf
        for i in 1:nv(state.graph.graph)
            geom = get_prop(state.graph.graph, i, :geom)
            for ll in geom
                if ll.lat > north
                    north = ll.lat
                end

                if ll.lat < south
                    south = ll.lat
                end

                if ll.lon < west
                    west = ll.lon
                end
            end
        end

        state.north = north
        state.west = west
        state.height_degrees = north - south

        draw(canvas)
    end

    signal_connect(reload_button, :clicked) do s
        state.graph = read_graph(state.graphpath, window)
        draw(canvas)
    end

    signal_connect(color_by_turn_button, :clicked) do _
        state.colormode = :turn
        draw(canvas)
    end

    signal_connect(color_by_system_button, :clicked) do _
        state.colormode = :system
        draw(canvas)
    end

    signal_connect(spt_step_button, :clicked) do _
        update_spt(state)
        draw(canvas)
    end

    signal_connect(vertex_label_button, :clicked) do _
        state.vertexlabels = !state.vertexlabels
        draw(canvas)
    end

    signal_connect(find_vertex_button, :clicked) do _
        v = parse(Int64, get_gtk_property(find_vertex_entry, :text, String))
        north = -Inf
        south = Inf
        west = Inf
        geom = get_prop(state.graph.graph, v, :geom)
        for ll in geom
            if ll.lat > north
                north = ll.lat
            end

            if ll.lat < south
                south = ll.lat
            end

            if ll.lon < west
                west = ll.lon
            end
        end

        state.west = west
        state.north = north
        state.height_degrees = north - south

        draw(canvas)
    end

    signal_connect(topo_button, :clicked) do _
        north, east, south, west = get_canvas_bbox(canvas, state)
        vertices = LibSpatialIndex.intersects(state.graph.index, [west, south], [east, north])
        topological_view(state, vertices, window)
    end

    signal_connect(color_by_strong_component_button, :clicked) do _
        if isempty(state.graph.strong_components)
            # find strong components
            for (i, component) in enumerate(strongly_connected_components(state.graph.graph))
                for v in component
                    state.graph.strong_components[v] = i
                end
            end
        end

        state.colormode = :strong_components
        draw(canvas)
    end

    showall(window)
    wait(exit_condition)
end

human_time(x) = "$(x ÷ 3600)h $((x % 3600) ÷ 60)m $(x % 60)s"