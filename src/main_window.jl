function main()
    window = Window("StreetRouterVisualizer.jl")
    main_layout = Box(:v)
    push!(window, main_layout)
    toolbar = Box(:h)
    push!(main_layout, toolbar)

    # add toolbar buttons
    open_button = Button("Open")
    quit_button = Button("Quit")
    push!(toolbar, open_button)
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

    # graph drawing
    graph::Union{Nothing, GraphAndMetadata} = nothing

    # the viewing area extent is defined by the NE corner and the width in degrees; this way
    # resizing the window zooms the existing view
    north = 35.913
    west = -79.057
    height_degrees = 0.01

    @guarded draw(canvas) do widget
        if isnothing(graph)
            ctx = getgc(canvas)
            h = height(canvas)
            w = width(canvas)
            
            # just paint it white
            rectangle(ctx, 0, 0, w, h)
            set_source_rgb(ctx, 1, 1, 1)
            fill(ctx)
        else
            draw_graph(graph, canvas, north, west, height_degrees)
        end
    end

    canvas.mouse.scroll = @guarded (wid, e) -> begin
        # figure out current extents
        _, east, south, _ = get_canvas_bbox(wid, north, west, height_degrees)

        # shrink or expand bbox around cursor
        # the point under the mouse should remain in exactly the same place
        # while everything else moves around it
        # how far across the screen the mouse is
        w = east - west
        h = north - south

        # figure out coordinates of scroll point
        scroll_lon = e.x / width(canvas) * w + west
        scroll_lat = e.y / height(canvas) * h + south


        frac_x = (scroll_lon - west) / w
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
        north = south + newh
        west = scroll_lon - neww * frac_x
        height_degrees = north - south

        draw(canvas, true)
    end

    # pan by dragging mouse
    panstart = nothing
    canvas.mouse.button1press = @guarded (wid, e) -> begin
        _, east, south, _ = get_canvas_bbox(wid, north, west, height_degrees)
        w = east - west
        h = north - south
        e_lon = e.x / width(canvas) * w + west
        e_lat = e.y / height(canvas) * h + south
        panstart = (e_lon, e_lat)
    end

    canvas.mouse.button1release = @guarded (wid, e) -> begin
        if !isnothing(panstart)
            _, east, south, _ = get_canvas_bbox(wid, north, west, height_degrees)
            w = east - west
            h = north - south
            e_lon = e.x / width(canvas) * w + west
            e_lat = e.y / height(canvas) * h + south
            west -= e_lon - panstart[1]
            north += e_lat - panstart[2]
            panstart = nothing
            draw(canvas)
        end
    end

    signal_connect(x -> notify(exit_condition), quit_button, :clicked)
    signal_connect(open_button, :clicked) do s
        file = open_dialog_native("Open graph", window, ("*",))
        set_gtk_property!(window, "title", "StreetRouterVisualizer.jl: $(basename(file))")
        graph = read_graph(file, window)

        # zoom so we can see it
        north = -Inf
        west = Inf
        south = Inf
        for i in 1:nv(graph.graph)
            geom = get_prop(graph.graph, i, :geom)
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

        height_degrees = north - south

        GAccessor.text(status, "$(basename(file))   |V|: $(nv(graph.graph))   |E|: $(ne(graph.graph))")

        draw(canvas, true)
    end

    showall(window)
    wait(exit_condition)
end
