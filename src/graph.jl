const ROUTE_COLOR="red"
const BEARING_DISTANCE = 15
const TURN_COLORS = collect(keys(filter(x -> sum(x[2]) < 128*3, pairs(Colors.color_names))))

function read_graph(filename, window)
    G = deserialize(filename)

    StreetRouter.compute_freeflow_weights!(G)

    # build a spatial index
    # note that geoms are attached to _vertices as this is an edge-based graph
    index = LibSpatialIndex.RTree(2)
    for v in 1:nv(G)
        geom = get_prop(G, v, :geom)
        lats = map(ll -> ll.lat, geom)
        lons = map(ll -> ll.lon, geom)
        LibSpatialIndex.insert!(index, v, [minimum(lons), minimum(lats)], [maximum(lons), maximum(lats)])
    end

    GraphAndMetadata(G, index)
end

function get_canvas_bbox(canvas, state::VisualizerState)
    h = height(canvas)
    w = width(canvas)
    width_degrees = state.height_degrees / h * w / cosd(state.north)
    east = state.west + width_degrees
    south = state.north - state.height_degrees

    (state.north, east, south, state.west)
end

function draw_graph(canvas, state::VisualizerState)
    ctx = getgc(canvas)
    h = height(canvas)
    w = width(canvas)

    drawing = Drawing(w, h)
    background("white")
    sethue("black")
    setline(1)


    # figure out the south and west corners
    # the width is figured based on height in degrees per pixel divided by teh cosine of latitude
    # to correct for degrees of longitude getting smaller near the poles
    north, east, south, west = get_canvas_bbox(canvas, state)

    # set scales appropriately
    # first, set relative scale of lon vs lat
    Luxor.scale(cosd(north), -1)

    # next, set overall scale
    Luxor.scale(h/ state.height_degrees)

    # pan to location
    Luxor.translate(-west, -north)
    
    # draw the graph
    # TODO switch to edge-based when zoomed in
    # drawing the non-edge-based graph, draw one path per vertex (which is a street segment)
    sethue(state.view == :turnbased ? "lightgray" : "black")
    setline(1)

    # always draw single segments
    visible_segments = LibSpatialIndex.intersects(state.graph.index, [west, south], [east, north])
    for v in visible_segments
        draw_single_segment(state, v)
    end

    sethue("black")
    if state.view == :turnbased
        for v in visible_segments
            draw_exploded_segment(state, v)
        end
    end

    Luxor.newpath()

    # and the path, if there is one
    if !isnothing(state.path)
        sethue(ROUTE_COLOR)
        setline(2)
        for (idx, vertex) in enumerate(state.path[1:end - 1])
            state.view == :normal && draw_single_segment(state, vertex)
            state.view == :turnbased && draw_exploded_segment(state, vertex, only_dest=state.path[idx + 1])
            Luxor.newpath()
        end
    end

    # draw the origin and destination
    node_radius_degrees = 10 / h * state.height_degrees
    !isnothing(state.origin) && draw_node(state.graph, state.origin, (0, 0, 1), node_radius_degrees)
    !isnothing(state.destination) && draw_node(state.graph, state.destination, (1, 0, 0), node_radius_degrees)

    # paint onto canvas
    # https://github.com/nodrygo/GtkLuxorNaiveDem
    Cairo.set_source_surface(ctx, drawing.surface)
    Cairo.paint(ctx)
end

function draw_node(graph, node, color, radius)
    sethue(color)
    geom = get_prop(graph.graph, node, :geom)
    Luxor.circle(geom[1].lon, geom[1].lat, radius, :fill)
end

# draw a single road segment (reprsented by a vertex)
function draw_single_segment(state, vertex)
    geom = get_prop(state.graph.graph, vertex, :geom)

    if length(geom) ≥ 2
        for (frll, toll) in zip(geom[1:end-1], geom[2:end])
            line(Luxor.Point(frll.lon, frll.lat), Luxor.Point(toll.lon, toll.lat), :stroke)
        end
    end
end

function offset_point(ll, heading, distance)
    pt = Luxor.Point(ll.lon * cosd(ll.lat), ll.lat)
    off = polar(distance / 111000, deg2rad(StreetRouter.OSM.circular_add(-heading, 90)))
    res = pt + off
    LatLon(res.y, res.x / cosd(ll.lat))
end

offset_geometry(geom, bearing, distance) = map(enumerate(geom)) do (idx, pt)
    current_heading = StreetRouter.OSM.compute_heading(geom[max(idx - 1, 1)], geom[min(idx + 1, length(geom))])
    offset_heading = StreetRouter.OSM.circular_add(current_heading, bearing)
    offset_latlon(pt, offset_heading, distance)
end

function get_location_for_vertex(state, vertex)
    geom = get_prop(state.graph.graph, vertex, :geom)

    # offset 10% meters down the line
    base, idx = get_point_along_line(geom, 5)

    init_bearing = StreetRouter.OSM.compute_heading(geom[1], base)

    # offset to the right
    offbase = offset_point(base, StreetRouter.OSM.circular_add(init_bearing, 90), 2)

    offbase, init_bearing
end 

Luxor.Point(ll::Union{LatLon, LLA}) = Luxor.Point(ll.lon, ll.lat)

function proj_dist(ll1, ll2) 
    lp1 = Luxor.Point(ll1.lon * cosd(ll1.lat), ll1.lat)
    lp2 =  Luxor.Point(ll2.lon * cosd(ll2.lat), ll2.lat)
    distance(lp1, lp2) * 111000
end


function turn_to_dest(origin, bearing, dest, turn_radius)
    bearing_to_dest = StreetRouter.OSM.compute_heading(origin, dest)
    
    turn_angle = StreetRouter.OSM.bearing_between(bearing, bearing_to_dest)
    
    bearing_to_center = if turn_angle < 0
        # left hand turn to destination
        StreetRouter.OSM.circular_add(bearing, -90)
    else
        StreetRouter.OSM.circular_add(bearing, +90)
    end

    arc_center = offset_point(origin, bearing_to_center, turn_radius)

    bearing_center_to_dest = StreetRouter.OSM.compute_heading(arc_center, dest)
    dist_to_dest = proj_dist(arc_center, dest)
    if (dist_to_dest < turn_radius)
        turn_to_dest(origin, bearing, dest, turn_radius / 2)
    else
        ang = acosd(turn_radius / dist_to_dest)
        bearing_tangent_to_dest = bearing_center_to_dest + ang
        # offset to the right of the bearing center to dest
        tangent_end = offset_point(arc_center, bearing_tangent_to_dest, turn_radius)
        # if turn_angle < 0
        #     # left turn, counterclockwise arc
        #     arc2r(Luxor.Point(arc_center), Luxor.Point(origin), Luxor.Point(tangent_end), :stroke)
        # else
        #     carc2r(Luxor.Point(arc_center), Luxor.Point(origin), Luxor.Point(tangent_end), :stroke)
        # end
        line(Luxor.Point(origin), Luxor.Point(tangent_end), :stroke)
        # line(Luxor.Point(arc_center), Luxor.Point(tangent_end))
        line(Luxor.Point(tangent_end), Luxor.Point(dest), :stroke)
    end
end

# give each restriction allowed path a unique color. since nearby restrictions
# in same system likely to have adjacent IDs, this should give unique colors for
# most restrictions
hue_for_restriction(restriction_id) = TURN_COLORS[restriction_id % length(TURN_COLORS) + 1]

function draw_exploded_segment(state, vertex; only_dest=nothing)
    if has_prop(state.graph.graph, vertex, :system_idx)
        # short circuit, draw point to point
        draw_turn(state, vertex, only_dest)
        return
    end

    geom = get_prop(state.graph.graph, vertex, :geom)
    origin_spl, bearing = get_location_for_vertex(state, vertex)
    
    nbrs = outneighbors(state.graph.graph, vertex)
    # if the outneighbors connect to a turn system, will be handled by draw_turn
    filter!(x -> !has_prop(state.graph.graph, x, :system_idx), nbrs)

    # sort l to r
    sort!(nbrs, by=nbr -> begin
        ang = get_prop(state.graph.graph, vertex, nbr, :turn_angle)
        # treat U turns as left turns
        ang > 170 ? -180 : ang
    end)

    off_angles = length(nbrs) > 1 ? range(-30, 30, length(nbrs)) : zeros(length(nbrs))
    
    for (nbr, offset_ang) in zip(nbrs, off_angles)
        if !isnothing(only_dest) && only_dest != nbr
            continue
        end

        dest_px, dbear = get_location_for_vertex(state, nbr)
        turn_ang = get_prop(state.graph.graph, vertex, nbr, :turn_angle)
        
        initial_offset = offset_point(origin_spl, bearing + offset_ang, 3)
        
        # line from origin to initial_offset
        line(Luxor.Point(origin_spl), Luxor.Point(initial_offset), :stroke)
            
        # draw parallel for a while
        dist = euclidean_distance(initial_offset, geom[end])
        
        bearing = StreetRouter.OSM.compute_heading(geom[1], geom[end])
        final_offset = offset_point(initial_offset, bearing, dist - 5)
                    
        line(Luxor.Point(initial_offset), Luxor.Point(final_offset), :stroke)
        bearing = StreetRouter.OSM.compute_heading(initial_offset, final_offset)
        #turn_to_dest(final_offset, bearing, dest_px, radius)
        line(Luxor.Point(final_offset), Luxor.Point(dest_px), :stroke)
    end
end

function draw_turn(state, vertex, only_dest)
    # otherwise, only draw the turn if this vertex is the start of the turn
    for nbr in inneighbors(state.graph.graph, vertex)
        if has_prop(state.graph.graph, nbr, :complex_restriction_idx)
            return
        end
    end

    # find the end of the turn
    current_v = vertex
    count = 1
    while true
        found_next = false
        for nbr in outneighbors(state.graph.graph, current_v)
            if has_prop(state.graph.graph, nbr, :complex_restriction_idx)
                current_v = nbr
                found_next = true
                count += 1
                break
            end
        end
        if !found_next
            break
        end
    end

    innbrs = inneighbors(state.graph.graph, vertex)
    @assert length(innbrs) == 1
    outnbrs = outneighbors(state.graph.graph, current_v)
    @assert length(outnbrs) == 1

    # get the color for the turn
    oldhue = Luxor.get_current_hue()
    Luxor.newpath()
    hue_idx = get_prop(state.graph.graph, vertex, state.colormode == :turn ? :complex_restriction_idx : :system_idx)
    hue = hue_for_restriction(hue_idx)
    sethue(isnothing(only_dest) ? hue : ROUTE_COLOR)

    frv, fang = get_location_for_vertex(state, innbrs[1])
    tov, toang = get_location_for_vertex(state, outnbrs[1])
    cp1 = offset_point(frv, fang, euclidean_distance(frv, tov) * 0.1)
    cp2 = offset_point(tov, StreetRouter.OSM.circular_add(toang, 180), euclidean_distance(frv, tov) * 0.1)

    move(Luxor.Point(frv))
    curve(Luxor.Point.([cp1, cp2, tov])...)
    #line(Luxor.Point(tov))

    Luxor.strokepath()
    Luxor.newpath()
    sethue(oldhue)
end

line_length(geom) = sum(euclidean_distance.(geom[1:end-1], geom[2:end]))

function get_point_along_line(geom, distance)
    # loop over geom, accumulating distances
    dist = 0.0
    
    for i in 2:length(geom)
        seg_dist = euclidean_distance(geom[i-1], geom[i])
        if dist + seg_dist > distance
            seg_frac = (distance - dist) / seg_dist
            # generate the midpoint
            return (
                LatLon(
                    geom[i - 1].lat + (geom[i].lat - geom[i - 1].lat) * seg_frac,
                    geom[i - 1].lon + (geom[i].lon - geom[i - 1].lon) * seg_frac,
                ),
                i
            )
        end
    end

    # if we haven't returned by here, return endpoint
    geom[end], length(geom) - 1
end

function route!(state)
    paths = dijkstra_shortest_paths(state.graph.graph, state.origin)
    # reconstruct the path
    state.path = enumerate_paths(paths, state.destination)
    state.distance = paths.dists[state.destination]
end

function lonlat_for_click(canvas, e, state)
    _, east, south, _ = get_canvas_bbox(canvas, state)
    w = east - state.west
    h = state.north - south
    e_lon = e.x / width(canvas) * w + state.west
    e_lat = (1 - e.y / height(canvas)) * h + south
    @info "clicked lat, lon" e_lon e_lat
    e_lon, e_lat
end

node_for_lonlat(lon, lat, G) = LibSpatialIndex.knn(G.index, [lon, lat], 1)[1]

