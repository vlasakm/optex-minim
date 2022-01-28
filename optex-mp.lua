local mplib = require("mplib")
local kpse = require("kpse")

local function mp_finder(name, mode, type)
    print("find", name, mode, type)
    if mode == "w" then
        return name
    else
        return kpse.find_file(name, type)
    end
end

local function mp_make_text(...)
    print("make_text", ...)
    return "image ( fill unitsquare )"
end

local function mp_new(format, math_mode)
    local mp = mplib.new {
        ini_version = true,
        find_file = mp_finder,
        math_mode = "scaled",
        extensions = 1, -- for make_text
        make_text = mp_make_text,
    }
    return mp
end

local function canvas_new()
    return {}
end

local function save(ctx)
    ctx[#ctx + 1] = { "q" }
end

local function restore(ctx)
    ctx[#ctx + 1] = { "Q" }
end

local function move_to(ctx, x, y)
    ctx[#ctx + 1] = { x, y, "m" }
end

local function line_to(ctx, x, y)
    ctx[#ctx + 1] = { x, y, "l" }
end

local function curve_to(ctx, x1, y1, x2, y2, x3, y3)
    ctx[#ctx + 1] = { x1, y1, x2, y2, x3, y3, "c" }
end

local function close_path(ctx)
    ctx[#ctx + 1] = { "h" }
end

local function stroke(ctx)
    ctx[#ctx + 1] = { "S" }
end

local function fill(ctx, evenodd)
    ctx[#ctx + 1] = { evenodd and "f*" or "f" }
end

local function strokefill(ctx, evenodd)
    ctx[#ctx + 1] = { evenodd and "B*" or "B" }
end

local function concat_clip(ctx, evenodd)
    ctx[#ctx + 1] = { evenodd and "W* n" or "W n" }
end

local function line_width(ctx, width)
    ctx[#ctx + 1] = { width, "w" }
end

local function concat_transform(ctx, txx, tyx, txy, tyy, tx, ty)
    ctx[#ctx + 1] = { txx, tyx, txy, tyy, tx, ty, "cm" }
end

local bend_tolerance = 131 / 65536
local abs = math.abs

local function mp_join_points(ctx, tr, p0, p1)
    local curved = true
    if p0.right_x == p0.x_coord and p0.right_y == p0.y_coord
            and p1.left_x == p1.x_coord and p1.left_y == p1.y_coord then
        curved = false
    end

    local d = p1.left_x - p0.right_x
    if abs(p0.right_x - p0.x_coord - d) <= bend_tolerance
            and abs(p1.x_coord - p1.left_x - d) <= bend_tolerance then
        d = p1.left_y - p0.right_y
        if abs(p0.right_y - p0.y_coord - d) <= bend_tolerance
                and abs(p1.y_coord - p1.left_y - d) <= bend_tolerance then
            curved = false
        end
    end

    local x3, y3 = tr(p1.x_coord, p1.y_coord)
    if curved then
        local x1, y1 = tr(p0.right_x, p0.right_y)
        local x2, y2 = tr(p1.right_x, p1.right_y)
        curve_to(ctx, x1, y1, x2, y2, x3, y3)
    else
        line_to(ctx, x3, y3)
    end
end

local function id2(x, y)
    return x, y
end

local function mp_path(ctx, path, tr)
    tr = tr or id2
    local curr = path[1]
    move_to(ctx, curr.x_coord, curr.y_coord)

    if #path > 1 then
        local prev = curr
        for i = 2, #path do
            curr = path[i]
            mp_join_points(ctx, tr, prev, curr)
            prev = curr
        end
        if prev.right_type ~= "endpoint" then
            -- end the cycle and close the path
            curr = path[1]
            mp_join_points(ctx, tr, prev, curr)
            close_path(ctx)
        end
    else
        -- single point
        line_to(ctx, curr.x_coord, curr.y_coord)
    end
end

local function mp_elliptical(ctx, obj, operation)
    local path = obj.path
    local pi = mplib.pen_info(obj)
    local txx, tyx, txy, tyy, tx, ty = pi.sx, pi.rx, pi.ry, pi.sy, pi.tx, pi.ty

    ctx[#ctx + 1] = { pi.width, "w" }

    if txx == 1 and tyx == 0 and txy == 0 and tyy == 1 and tx == 0 and ty == 0 then
        -- no transform (circular pen)
        mp_path(ctx, path)
        operation(ctx)
    else
        -- transform (elliptical pen)
        save(ctx)
        -- the transformation distorts the coordinate system such that circular
        -- pen will achieve elliptical pen, but since we don't want to change
        -- the path, we use inverse transformation for all path points
        concat_transform(ctx, txx, tyx, txy, tyy, tx, ty)
        local det_inv = 1 / (txx * tyy - tyx * txy)
        mp_path(ctx, path, function(x, y)
            -- inverse transform
            return (tyy*x - txy*y) * det_inv, (txx*y - tyx*x) * det_inv
        end)
        operation(ctx)
        restore(ctx)
    end
end

local fmt = string.format

local function int_fmt(int)
    return fmt("%d", int)
end

local function canvas_tostring(ctx)
    for i = 1, #ctx do
        ctx[i] = table.concat(ctx[i], " ")
    end
    return table.concat(ctx, "\n")
end

local function canvas_add_mp_objects(ctx, objects)
    for i, obj in ipairs(objects) do
        local objtype = obj.type
        if objtype == "outline" or objtype == "fill" then
            local pen = obj.pen
            local path, htap = obj.path, obj.htap
            if obj.linejoin then
                ctx[#ctx + 1] = { int_fmt(obj.linejoin), "j" }
            end
            if obj.linecap then
                ctx[#ctx + 1] = { int_fmt(obj.linecap), "J" }
            end
            if obj.miterlimit then
                ctx[#ctx + 1] = { obj.miterlimit, "M" }
            end
            if pen and pen.type == "elliptical" then
                -- elliptical / transformed pencircle ("filldraw" or "draw")
                local operation = objtype == "fill" and strokefill or stroke
                mp_elliptical(ctx, obj, operation)
            else
                -- either a) simple fill without pen ("fill")
                --        b) polygonal pen, precomputed by mplib, just need to fill path and htap
                if path then
                    mp_path(ctx, path)
                    fill(ctx)
                end
                if htap then
                    mp_path(ctx, path)
                    fill(ctx)
                end
            end
        elseif objtype == "start_clip" then
            save(ctx)
            mp_path(ctx, path)
            concat_clip(ctx)
        elseif objtype == "stop_clip" then
            restore(ctx)
        else
            -- "start_bounds" and "stop_bounds" can be safely ignored
            -- "special" and "text" are not supported
        end
    end
end

local onebp = tex.sp("1bp")
local function boxup_figure(mpfigure)
    local objects = mpfigure:objects()
    local canvas = canvas_new()
    save(canvas)
    canvas_add_mp_objects(canvas, objects)
    restore(canvas)

    local literal = canvas_tostring(canvas)
    local n = node.new("whatsit", "pdf_literal")
    n.data = literal
    print(literal)
    n = node.hpack(n)
    local bbox = mpfigure:boundingbox()
    n.width = (bbox[3] - bbox[1]) * onebp
    n.height = (bbox[4] - bbox[2]) * onebp
    n.depth = 0
    return n
end

define_lua_command("_mp_boxes", function()
    local mp = mp_new()
    local input = token.scan_string()
    local result = mp:execute(input)
    if result.status ~= 0 then
        print("failed", result.status)
        print(result.term)
        print(result.error)
    end
    for _, fig in ipairs(result.fig) do
        node.write(boxup_figure(fig))
    end
end)
