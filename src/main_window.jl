function main()
    window = Window("StreetRouterVisualizer.jl")
    main_layout = Box(:v)
    push!(window, main_layout)
    toolbar = Box(:h)
    push!(main_layout, toolbar)

    # add toolbar button
    open_button = Button("Open")
    quit_button = Button("Quit")
    push!(toolbar, open_button)
    push!(toolbar, quit_button)
    exit_condition = Condition()
    signal_connect(x -> notify(exit_condition), quit_button, :clicked)
    signal_connect(open_button, :clicked) do s
        file = open_dialog_native("Open graph", window, ("*",))
        set_gtk_property!(window, "title", "StreetRouterVisualizer.jl: $(basename(file))")
    end

    canvas = Canvas()
    push!(main_layout, canvas)

    showall(window)
    wait(exit_condition)
end
