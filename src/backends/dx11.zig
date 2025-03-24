const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
pub const win32 = @import("win32").everything;

pub const Context = *align(1) @This();

const log = std.log.scoped(.Dx11Backend);

pub const WindowState = struct {
    vsync: bool,

    dvui_window: dvui.Window,

    device: *win32.ID3D11Device,
    device_context: *win32.ID3D11DeviceContext,
    swap_chain: *win32.IDXGISwapChain,

    render_target: ?*win32.ID3D11RenderTargetView = null,
    dx_options: DirectxOptions = .{},

    // TODO: Implement touch events
    //   might require help with that,
    //   since i have no touch input device that runs windows.
    /// Whether there are touch events
    touch_mouse_events: bool = false,
    /// Whether to log events
    log_events: bool = false,

    /// The arena allocator (usually)
    arena: std.mem.Allocator = undefined,

    pub fn deinit(state: *WindowState) void {
        state.dvui_window.deinit();
        if (state.render_target) |rt| {
            _ = rt.IUnknown.Release();
        }
        _ = state.device.IUnknown.Release();
        _ = state.device_context.IUnknown.Release();
        _ = state.swap_chain.IUnknown.Release();
        state.dx_options.deinit();
    }
};

const DvuiKey = union(enum) {
    /// A keyboard button press
    keyboard_key: dvui.enums.Key,
    /// A mouse button press
    mouse_key: dvui.enums.Button,
    /// Mouse move event
    mouse_event: struct { x: i16, y: i16 },
    /// Mouse wheel scroll event
    wheel_event: i16,
    /// No action
    none: void,
};

const KeyEvent = struct {
    /// The type of event emitted
    target: DvuiKey,
    /// What kind of action the event emitted
    action: enum { down, up, none },
};

const DirectxOptions = struct {
    vertex_shader: ?*win32.ID3D11VertexShader = null,
    vertex_bytes: ?*win32.ID3DBlob = null,
    pixel_shader: ?*win32.ID3D11PixelShader = null,
    pixel_bytes: ?*win32.ID3DBlob = null,
    vertex_layout: ?*win32.ID3D11InputLayout = null,
    vertex_buffer: ?*win32.ID3D11Buffer = null,
    index_buffer: ?*win32.ID3D11Buffer = null,
    texture_view: ?*win32.ID3D11ShaderResourceView = null,
    sampler: ?*win32.ID3D11SamplerState = null,
    rasterizer: ?*win32.ID3D11RasterizerState = null,
    blend_state: ?*win32.ID3D11BlendState = null,

    pub fn deinit(self: DirectxOptions) void {
        // is there really no way to express this better?
        if (self.vertex_shader) |vs| {
            _ = vs.IUnknown.Release();
        }
        if (self.vertex_bytes) |vb| {
            _ = vb.IUnknown.Release();
        }
        if (self.pixel_shader) |ps| {
            _ = ps.IUnknown.Release();
        }
        if (self.pixel_bytes) |pb| {
            _ = pb.IUnknown.Release();
        }
        if (self.vertex_layout) |vl| {
            _ = vl.IUnknown.Release();
        }
        if (self.vertex_buffer) |vb| {
            _ = vb.IUnknown.Release();
        }
        if (self.index_buffer) |ib| {
            _ = ib.IUnknown.Release();
        }
        if (self.texture_view) |tv| {
            _ = tv.IUnknown.Release();
        }
        if (self.sampler) |s| {
            _ = s.IUnknown.Release();
        }
        if (self.rasterizer) |r| {
            _ = r.IUnknown.Release();
        }
        if (self.blend_state) |bs| {
            _ = bs.IUnknown.Release();
        }
    }
};

pub const InitOptions = struct {
    dvui_gpa: std.mem.Allocator,
    /// The allocator used for temporary allocations used during init()
    allocator: std.mem.Allocator,
    /// The initial size of the application window
    size: ?dvui.Size = null,
    /// Set the minimum size of the window
    min_size: ?dvui.Size = null,
    /// Set the maximum size of the window
    max_size: ?dvui.Size = null,
    vsync: bool,
    /// Set to false if the window class has already been registered, either directly
    /// via RegisterClass or indirectly via a previous call to initWindow.
    register_window_class: bool = true,

    window_class: [*:0]const u16 = default_window_class,

    /// The application title to display
    title: [:0]const u8,
    /// content of a PNG image (or any other format stb_image can load)
    /// tip: use @embedFile
    icon: ?[]const u8 = null,
};

pub const Directx11Options = struct {
    /// The device
    device: *win32.ID3D11Device,
    /// The Context
    device_context: *win32.ID3D11DeviceContext,
    /// The Swap chain
    swap_chain: *win32.IDXGISwapChain,
};

const XMFLOAT2 = extern struct { x: f32, y: f32 };
const XMFLOAT3 = extern struct { x: f32, y: f32, z: f32 };
const XMFLOAT4 = extern struct { r: f32, g: f32, b: f32, a: f32 };
const SimpleVertex = extern struct { position: XMFLOAT3, color: XMFLOAT4, texcoord: XMFLOAT2 };

const shader =
    \\struct PSInput
    \\{
    \\    float4 position : SV_POSITION;
    \\    float4 color : COLOR;
    \\    float2 texcoord : TEXCOORD0;
    \\};
    \\
    \\PSInput VSMain(float4 position : POSITION, float4 color : COLOR, float2 texcoord : TEXCOORD0)
    \\{
    \\    PSInput result;
    \\
    \\    result.position = position;
    \\    result.color = color;
    \\    result.texcoord = texcoord;
    \\
    \\    return result;
    \\}
    \\
    \\Texture2D myTexture : register(t0);
    \\SamplerState samplerState : register(s0);
    \\
    \\float4 PSMain(PSInput input) : SV_TARGET
    \\{
    \\    if(input.texcoord.x < 0 || input.texcoord.x > 1 || input.texcoord.y < 0 || input.texcoord.y > 1) return input.color;
    \\    float4 sampled = myTexture.Sample(samplerState, input.texcoord);
    \\    return sampled * input.color;
    \\}
;

/// Sets the directx viewport to the internally used dvui.Size
/// Call this *after* setDimensions
fn setViewport(state: *WindowState, width: f32, height: f32) void {
    var vp = win32.D3D11_VIEWPORT{
        .TopLeftX = 0.0,
        .TopLeftY = 0.0,
        .Width = width,
        .Height = height,
        .MinDepth = 0.0,
        .MaxDepth = 1.0,
    };
    state.device_context.RSSetViewports(1, @ptrCast(&vp));
}

pub fn getWindow(context: Context) *dvui.Window {
    return &stateFromHwnd(hwndFromContext(context)).dvui_window;
}

pub const default_window_class = win32.L("DvuiWindow");

pub const RegisterClassOptions = struct {
    /// styles in addition to DBLCLICKS
    style: win32.WNDCLASS_STYLES = .{},
    // NOTE: we could allow the user to provide their own wndproc which we could
    //       call before or after ours
    //wndproc: ...,
    class_extra: c_int = 0,
    // NOTE: the dx11 backend uses the first @sizeOf(*anyopaque) bytes, any length
    //       added here will be offset by that many bytes
    window_extra_after_sizeof_ptr: c_int = 0,
    instance: union(enum) { this_module, custom: ?win32.HINSTANCE } = .this_module,
    cursor: union(enum) { arrow, custom: ?win32.HICON } = .arrow,
    icon: ?win32.HICON = null,
    icon_small: ?win32.HICON = null,
    bg_brush: ?win32.HBRUSH = null,
    menu_name: ?[*:0]const u16 = null,
};

/// A wrapper for win32.RegisterClass that registers a window class compatible
/// with initWindow. Returns error.Win32 on failure, call win32.GetLastError()
/// for the error code.
///
/// RegisterClass can only be called once for a given name (unless it's been unregistered
/// via UnregisterClass). Typically there's no reason to unregister a window class.
pub fn RegisterClass(name: [*:0]const u16, opt: RegisterClassOptions) error{Win32}!void {
    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = @bitCast(@as(u32, @bitCast(win32.WNDCLASS_STYLES{ .DBLCLKS = 1 })) | @as(u32, @bitCast(opt.style))),
        .lpfnWndProc = wndProc,
        .cbClsExtra = opt.class_extra,
        .cbWndExtra = @sizeOf(usize) + opt.window_extra_after_sizeof_ptr,
        .hInstance = switch (opt.instance) {
            .this_module => win32.GetModuleHandleW(null),
            .custom => |i| i,
        },
        .hIcon = opt.icon,
        .hIconSm = opt.icon_small,
        .hCursor = switch (opt.cursor) {
            .arrow => win32.LoadCursorW(null, win32.IDC_ARROW),
            .custom => |c| c,
        },
        .hbrBackground = opt.bg_brush,
        .lpszMenuName = opt.menu_name,
        .lpszClassName = name,
    };
    if (0 == win32.RegisterClassExW(&wc)) return error.Win32;
}

/// Creates a new DirectX window for you, as well as initializes all the
/// DirectX options for you
/// The caller just needs to clean up everything by calling `deinit` on the Dx11Backend
pub fn initWindow(window_state: *WindowState, options: InitOptions) !Context {
    if (options.register_window_class) RegisterClass(
        options.window_class,
        .{},
    ) catch win32.panicWin32("RegisterClass", win32.GetLastError());

    const style = win32.WS_OVERLAPPEDWINDOW;
    const style_ex: win32.WINDOW_EX_STYLE = .{ .APPWINDOW = 1, .WINDOWEDGE = 1 };

    const create_args: CreateWindowArgs = .{
        .window_state = window_state,
        .vsync = options.vsync,
        .dvui_gpa = options.dvui_gpa,
    };
    const hwnd = blk: {
        const wnd_title = try std.unicode.utf8ToUtf16LeAllocZ(options.allocator, options.title);
        defer options.allocator.free(wnd_title);
        break :blk win32.CreateWindowExW(
            style_ex,
            options.window_class,
            wnd_title,
            style,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            null,
            null,
            win32.GetModuleHandleW(null),
            @constCast(@ptrCast(&create_args)),
        ) orelse {
            if (create_args.err) |err| return err;
            win32.panicWin32("CreateWindow", win32.GetLastError());
        };
    };

    if (options.size) |size| {
        const dpi = win32.dpiFromHwnd(hwnd);
        const screen_width = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSCREEN), dpi);
        const screen_height = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSCREEN), dpi);
        var wnd_size: win32.RECT = .{
            .left = 0,
            .top = 0,
            .right = @min(screen_width, @as(i32, @intFromFloat(@round(win32.scaleDpi(f32, size.w, dpi))))),
            .bottom = @min(screen_height, @as(i32, @intFromFloat(@round(win32.scaleDpi(f32, size.h, dpi))))),
        };
        _ = win32.AdjustWindowRectEx(&wnd_size, style, 0, style_ex);

        const wnd_width = wnd_size.right - wnd_size.left;
        const wnd_height = wnd_size.bottom - wnd_size.top;
        _ = win32.SetWindowPos(
            hwnd,
            null,
            @divFloor(screen_width - wnd_width, 2),
            @divFloor(screen_height - wnd_height, 2),
            wnd_width,
            wnd_height,
            win32.SWP_NOCOPYBITS,
        );
    }
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });
    _ = win32.UpdateWindow(hwnd);
    return contextFromHwnd(hwnd);
}

/// Cleanup routine
pub fn deinit(self: Context) void {
    if (0 == win32.DestroyWindow(hwndFromContext(self))) win32.panicWin32("DestroyWindow", win32.GetLastError());
}

/// Resizes the SwapChain based on the new window size
/// This is only useful if you have your own directx stuff to manage
pub fn handleSwapChainResizing(self: Context, width: c_uint, height: c_uint) !void {
    const state = stateFromHwnd(hwndFromContext(self));
    cleanupRenderTarget(state);
    _ = state.swap_chain.ResizeBuffers(0, width, height, win32.DXGI_FORMAT_UNKNOWN, 0);
    try createRenderTarget(state);
}

/// Call this first in your main event loop.
/// This is NON-OPTIONAL!
/// Your window will freeze otherwise.
/// Time spent figuring this out: ~4 hours
pub fn isExitRequested() bool {
    var msg: win32.MSG = undefined;

    while (win32.PeekMessageA(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
        if (msg.message == win32.WM_QUIT) {
            return true;
        }
    }

    return false;
}

fn isOk(res: win32.HRESULT) bool {
    return res >= 0;
}

fn initShader(state: *WindowState) !void {
    var error_message: ?*win32.ID3DBlob = null;

    var vs_blob: ?*win32.ID3DBlob = null;
    const compile_shader = win32.D3DCompile(
        shader.ptr,
        shader.len,
        null,
        null,
        null,
        "VSMain",
        "vs_4_0",
        win32.D3DCOMPILE_ENABLE_STRICTNESS,
        0,
        &vs_blob,
        &error_message,
    );
    if (!isOk(compile_shader)) {
        if (error_message == null) {
            log.err("hresult of error message was skewed: {x}", .{compile_shader});
            return error.VertexShaderInitFailed;
        }

        defer _ = error_message.?.IUnknown.Release();
        const as_str: [*:0]const u8 = @ptrCast(error_message.?.vtable.GetBufferPointer(error_message.?));
        log.err("vertex shader compilation failed with:\n{s}", .{as_str});
        return error.VertexShaderInitFailed;
    }

    var ps_blob: ?*win32.ID3DBlob = null;
    const ps_res = win32.D3DCompile(
        shader.ptr,
        shader.len,
        null,
        null,
        null,
        "PSMain",
        "ps_4_0",
        win32.D3DCOMPILE_ENABLE_STRICTNESS,
        0,
        &ps_blob,
        &error_message,
    );
    if (!isOk(ps_res)) {
        if (error_message == null) {
            log.err("hresult of error message was skewed: {x}", .{compile_shader});
            return error.PixelShaderInitFailed;
        }

        defer _ = error_message.?.IUnknown.Release();
        const as_str: [*:0]const u8 = @ptrCast(error_message.?.vtable.GetBufferPointer(error_message.?));
        log.err("pixel shader compilation failed with: {s}", .{as_str});
        return error.PixelShaderInitFailed;
    }

    state.dx_options.vertex_bytes = vs_blob.?;
    var vertex_shader_result: @TypeOf(state.dx_options.vertex_shader.?) = undefined;
    const create_vs = state.device.CreateVertexShader(
        @ptrCast(state.dx_options.vertex_bytes.?.GetBufferPointer()),
        state.dx_options.vertex_bytes.?.GetBufferSize(),
        null,
        &vertex_shader_result,
    );
    state.dx_options.vertex_shader = vertex_shader_result;

    if (!isOk(create_vs)) {
        return error.CreateVertexShaderFailed;
    }

    state.dx_options.pixel_bytes = ps_blob.?;
    var pixel_shader_result: @TypeOf(state.dx_options.pixel_shader.?) = undefined;
    const create_ps = state.device.CreatePixelShader(
        @ptrCast(state.dx_options.pixel_bytes.?.GetBufferPointer()),
        state.dx_options.pixel_bytes.?.GetBufferSize(),
        null,
        &pixel_shader_result,
    );
    state.dx_options.pixel_shader = pixel_shader_result;

    if (!isOk(create_ps)) {
        return error.CreatePixelShaderFailed;
    }
}

fn createRasterizerState(state: *WindowState) !void {
    var raster_desc = std.mem.zeroes(win32.D3D11_RASTERIZER_DESC);
    raster_desc.FillMode = win32.D3D11_FILL_MODE.SOLID;
    raster_desc.CullMode = win32.D3D11_CULL_BACK;
    raster_desc.FrontCounterClockwise = 1;
    raster_desc.DepthClipEnable = 0;
    raster_desc.ScissorEnable = 1;

    var rasterizer_result: @TypeOf(state.dx_options.rasterizer.?) = undefined;
    const rasterizer_res = state.device.CreateRasterizerState(&raster_desc, &rasterizer_result);
    state.dx_options.rasterizer = rasterizer_result;
    if (!isOk(rasterizer_res)) {
        return error.RasterizerInitFailed;
    }

    state.device_context.RSSetState(state.dx_options.rasterizer);
}

fn createRenderTarget(state: *WindowState) !void {
    var back_buffer: ?*win32.ID3D11Texture2D = null;

    _ = state.swap_chain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
    defer _ = back_buffer.?.IUnknown.Release();

    var render_target_result: @TypeOf(state.render_target.?) = undefined;
    _ = state.device.CreateRenderTargetView(
        @ptrCast(back_buffer),
        null,
        &render_target_result,
    );
    state.render_target = render_target_result;
}

fn cleanupRenderTarget(state: *WindowState) void {
    if (state.render_target) |mrtv| {
        _ = mrtv.IUnknown.Release();
        state.render_target = null;
    }
}

fn createInputLayout(state: *WindowState) !void {
    const input_layout_desc = &[_]win32.D3D11_INPUT_ELEMENT_DESC{
        .{ .SemanticName = "POSITION", .SemanticIndex = 0, .Format = win32.DXGI_FORMAT_R32G32B32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 0, .InputSlotClass = win32.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
        .{ .SemanticName = "COLOR", .SemanticIndex = 0, .Format = win32.DXGI_FORMAT_R32G32B32A32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 12, .InputSlotClass = win32.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
        .{ .SemanticName = "TEXCOORD", .SemanticIndex = 0, .Format = win32.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 28, .InputSlotClass = win32.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
    };

    const num_elements = input_layout_desc.len;

    var vertex_layout_result: @TypeOf(state.dx_options.vertex_layout.?) = undefined;
    const res = state.device.CreateInputLayout(
        input_layout_desc,
        num_elements,
        @ptrCast(state.dx_options.vertex_bytes.?.GetBufferPointer()),
        state.dx_options.vertex_bytes.?.GetBufferSize(),
        &vertex_layout_result,
    );
    state.dx_options.vertex_layout = vertex_layout_result;

    if (!isOk(res)) {
        return error.VertexLayoutCreationFailed;
    }

    state.device_context.IASetInputLayout(state.dx_options.vertex_layout);
}

fn recreateShaderView(state: *WindowState, texture: *anyopaque) void {
    const tex: *win32.ID3D11Texture2D = @ptrCast(@alignCast(texture));

    const rvd = win32.D3D11_SHADER_RESOURCE_VIEW_DESC{
        .Format = win32.DXGI_FORMAT.R8G8B8A8_UNORM,
        .ViewDimension = win32.D3D_SRV_DIMENSION_TEXTURE2D,
        .Anonymous = .{
            .Texture2D = .{
                .MostDetailedMip = 0,
                .MipLevels = 1,
            },
        },
    };

    if (state.dx_options.texture_view) |tv| {
        _ = tv.IUnknown.Release();
    }

    var texture_view_result: @TypeOf(state.dx_options.texture_view.?) = undefined;
    const rv_result = state.device.CreateShaderResourceView(
        &tex.ID3D11Resource,
        &rvd,
        &texture_view_result,
    );
    state.dx_options.texture_view = texture_view_result;

    if (!isOk(rv_result)) {
        log.err("Texture View creation failed", .{});
        @panic("couldn't create texture view");
    }
}

fn createSampler(state: *WindowState) !void {
    var samp_desc = std.mem.zeroes(win32.D3D11_SAMPLER_DESC);
    samp_desc.Filter = win32.D3D11_FILTER.MIN_MAG_POINT_MIP_LINEAR;
    samp_desc.AddressU = win32.D3D11_TEXTURE_ADDRESS_MODE.WRAP;
    samp_desc.AddressV = win32.D3D11_TEXTURE_ADDRESS_MODE.WRAP;
    samp_desc.AddressW = win32.D3D11_TEXTURE_ADDRESS_MODE.WRAP;

    var blend_desc = std.mem.zeroes(win32.D3D11_BLEND_DESC);
    blend_desc.RenderTarget[0].BlendEnable = 1;
    blend_desc.RenderTarget[0].SrcBlend = win32.D3D11_BLEND_ONE;
    blend_desc.RenderTarget[0].DestBlend = win32.D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOp = win32.D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].SrcBlendAlpha = win32.D3D11_BLEND_ONE;
    blend_desc.RenderTarget[0].DestBlendAlpha = win32.D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOpAlpha = win32.D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].RenderTargetWriteMask = @intFromEnum(win32.D3D11_COLOR_WRITE_ENABLE_ALL);

    // TODO: Handle errors better
    var blend_state_result: @TypeOf(state.dx_options.blend_state.?) = undefined;
    _ = state.device.CreateBlendState(&blend_desc, &blend_state_result);
    state.dx_options.blend_state = blend_state_result;
    _ = state.device_context.OMSetBlendState(state.dx_options.blend_state, null, 0xffffffff);

    var sampler_result: @TypeOf(state.dx_options.sampler.?) = undefined;
    const sampler = state.device.CreateSamplerState(&samp_desc, &sampler_result);
    state.dx_options.sampler = sampler_result;

    if (!isOk(sampler)) {
        log.err("sampler state could not be iniitialized", .{});
        return error.SamplerStateUninitialized;
    }
}

// If you don't know what they are used for... just don't use them, alright?
fn createBuffer(state: *WindowState, bind_type: anytype, comptime InitialType: type, initial_data: []const InitialType) !*win32.ID3D11Buffer {
    var bd = std.mem.zeroes(win32.D3D11_BUFFER_DESC);
    bd.Usage = win32.D3D11_USAGE_DEFAULT;
    bd.ByteWidth = @intCast(@sizeOf(InitialType) * initial_data.len);
    bd.BindFlags = bind_type;
    bd.CPUAccessFlags = .{};

    var data: win32.D3D11_SUBRESOURCE_DATA = undefined;
    data.pSysMem = @ptrCast(initial_data.ptr);

    var buffer: *win32.ID3D11Buffer = undefined;
    _ = state.device.CreateBuffer(&bd, &data, &buffer);

    // argument no longer pointer-to-optional since zigwin32 update - 2025-01-10
    //if (buffer) |buf| {
    return buffer;
    //} else {
    //    return error.BufferFailedToCreate;
    //}
}

// ############ Satisfy DVUI interfaces ############
pub fn textureCreate(self: Context, pixels: [*]u8, width: u32, height: u32, ti: dvui.enums.TextureInterpolation) dvui.Texture {
    _ = ti; // autofix
    const state = stateFromHwnd(hwndFromContext(self));

    var texture: *win32.ID3D11Texture2D = undefined;
    var tex_desc = win32.D3D11_TEXTURE2D_DESC{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = win32.DXGI_FORMAT.R8G8B8A8_UNORM,
        .SampleDesc = .{
            .Count = 1,
            .Quality = 0,
        },
        .Usage = win32.D3D11_USAGE_DEFAULT,
        .BindFlags = win32.D3D11_BIND_SHADER_RESOURCE,
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };

    var resource_data = std.mem.zeroes(win32.D3D11_SUBRESOURCE_DATA);
    resource_data.pSysMem = pixels;
    resource_data.SysMemPitch = width * 4; // 4 byte per pixel (RGBA)

    const tex_creation = state.device.CreateTexture2D(
        &tex_desc,
        &resource_data,
        &texture,
    );

    if (!isOk(tex_creation)) {
        log.err("Texture creation failed.", .{});
        @panic("couldn't create texture");
    }

    return dvui.Texture{ .ptr = texture, .width = width, .height = height };
}

pub fn textureCreateTarget(self: Context, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.Texture {
    _ = self;
    _ = width;
    _ = height;
    _ = interpolation;
    dvui.log.debug("dx11 textureCreateTarget unimplemented", .{});
    return error.TextureCreate;
}

pub fn textureRead(self: Context, texture: dvui.Texture, pixels_out: [*]u8) error{TextureRead}!void {
    _ = self;
    _ = texture;
    _ = pixels_out;
    dvui.log.debug("dx11 textureRead unimplemented", .{});
    return error.TextureRead;
}

pub fn textureDestroy(self: Context, texture: dvui.Texture) void {
    _ = self;
    const tex: *win32.ID3D11Texture2D = @ptrCast(@alignCast(texture.ptr));
    _ = tex.IUnknown.Release();
}

pub fn renderTarget(self: Context, texture: ?dvui.Texture) void {
    _ = self;
    _ = texture;
    dvui.log.debug("dx11 renderTarget unimplemented", .{});
}

pub fn drawClippedTriangles(
    self: Context,
    texture: ?dvui.Texture,
    vtx: []const dvui.Vertex,
    idx: []const u16,
    clipr: ?dvui.Rect,
) void {
    const state = stateFromHwnd(hwndFromContext(self));
    const client_size = win32.getClientSize(hwndFromContext(self));
    setViewport(state, @floatFromInt(client_size.cx), @floatFromInt(client_size.cy));

    if (state.render_target == null) {
        createRenderTarget(state) catch |err| {
            log.err("render target could not be initialized: {}", .{err});
            return;
        };
    }

    if (state.dx_options.vertex_shader == null or state.dx_options.pixel_shader == null) {
        initShader(state) catch |err| {
            log.err("shaders could not be initialized: {}", .{err});
            return;
        };
    }

    if (state.dx_options.vertex_layout == null) {
        createInputLayout(state) catch |err| {
            log.err("Failed to create vertex layout: {}", .{err});
            return;
        };
    }

    if (state.dx_options.sampler == null) {
        createSampler(state) catch |err| {
            log.err("sampler could not be initialized: {}", .{err});
            return;
        };
    }

    if (state.dx_options.rasterizer == null) {
        createRasterizerState(state) catch |err| {
            log.err("Creating rasterizer failed: {}", .{err});
        };
    }

    var stride: usize = @sizeOf(SimpleVertex);
    var offset: usize = 0;
    const converted_vtx = convertVertices(state.arena, .{
        .w = @floatFromInt(client_size.cx),
        .h = @floatFromInt(client_size.cy),
    }, vtx, texture == null) catch @panic("OOM");
    defer state.arena.free(converted_vtx);

    // Do yourself a favour and don't touch it.
    // End() isn't being called all the time, so it's kind of futile.
    if (state.dx_options.vertex_buffer) |vb| {
        _ = vb.IUnknown.Release();
    }
    state.dx_options.vertex_buffer = createBuffer(state, win32.D3D11_BIND_VERTEX_BUFFER, SimpleVertex, converted_vtx) catch {
        log.err("no vertex buffer created", .{});
        return;
    };

    // Do yourself a favour and don't touch it.
    // End() isn't being called all the time, so it's kind of futile.
    if (state.dx_options.index_buffer) |ib| {
        _ = ib.IUnknown.Release();
    }
    state.dx_options.index_buffer = createBuffer(state, win32.D3D11_BIND_INDEX_BUFFER, u16, idx) catch {
        log.err("no index buffer created", .{});
        return;
    };

    setViewport(state, @floatFromInt(client_size.cx), @floatFromInt(client_size.cy));

    if (texture) |tex| recreateShaderView(state, tex.ptr);

    var scissor_rect: ?win32.RECT = std.mem.zeroes(win32.RECT);
    var nums: u32 = 1;
    state.device_context.RSGetScissorRects(&nums, @ptrCast(&scissor_rect));

    if (clipr) |cr| {
        const new_clip: win32.RECT = .{
            .left = @intFromFloat(cr.x),
            .top = @intFromFloat(cr.y),
            .right = @intFromFloat(@ceil(cr.x + cr.w)),
            .bottom = @intFromFloat(@ceil(cr.y + cr.h)),
        };
        state.device_context.RSSetScissorRects(nums, @ptrCast(&new_clip));
    } else {
        scissor_rect = null;
    }

    state.device_context.IASetVertexBuffers(0, 1, @ptrCast(&state.dx_options.vertex_buffer), @ptrCast(&stride), @ptrCast(&offset));
    state.device_context.IASetIndexBuffer(state.dx_options.index_buffer, win32.DXGI_FORMAT.R16_UINT, 0);
    state.device_context.IASetPrimitiveTopology(win32.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    state.device_context.OMSetRenderTargets(1, @ptrCast(&state.render_target), null);
    state.device_context.VSSetShader(state.dx_options.vertex_shader, null, 0);
    state.device_context.PSSetShader(state.dx_options.pixel_shader, null, 0);

    state.device_context.PSSetShaderResources(0, 1, @ptrCast(&state.dx_options.texture_view));
    state.device_context.PSSetSamplers(0, 1, @ptrCast(&state.dx_options.sampler));
    state.device_context.DrawIndexed(@intCast(idx.len), 0, 0);
    if (scissor_rect) |srect| state.device_context.RSSetScissorRects(nums, @ptrCast(&srect));
}

pub fn begin(self: Context, arena: std.mem.Allocator) void {
    const state = stateFromHwnd(hwndFromContext(self));
    state.arena = arena;

    const pixel_size = self.pixelSize();
    var scissor_rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intFromFloat(@round(pixel_size.w)),
        .bottom = @intFromFloat(@round(pixel_size.h)),
    };
    state.device_context.RSSetScissorRects(1, @ptrCast(&scissor_rect));

    var clear_color = [_]f32{ 1.0, 1.0, 1.0, 0.0 };
    state.device_context.ClearRenderTargetView(state.render_target orelse return, @ptrCast((&clear_color).ptr));
}

pub fn end(self: Context) void {
    const state = stateFromHwnd(hwndFromContext(self));
    _ = state.swap_chain.Present(if (state.vsync) 1 else 0, 0);
}

pub fn pixelSize(self: Context) dvui.Size {
    const client_size = win32.getClientSize(hwndFromContext(self));
    return .{
        .w = @floatFromInt(client_size.cx),
        .h = @floatFromInt(client_size.cy),
    };
}

pub fn windowSize(self: Context) dvui.Size {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetWindowRect(hwndFromContext(self), &rect)) win32.panicWin32(
        "GetWindowRect",
        win32.GetLastError(),
    );
    return .{
        .w = @floatFromInt(rect.right - rect.left),
        .h = @floatFromInt(rect.bottom - rect.top),
    };
}

pub fn contentScale(self: Context) f32 {
    _ = self;
    return 1.0;
    //return @as(f32, @floatFromInt(win32.dpiFromHwnd(hwndFromContext(self)))) / 96.0;
}

pub fn hasEvent(_: Context) bool {
    return false;
}

pub fn backend(self: Context) dvui.Backend {
    return dvui.Backend.init(self, @This());
}

pub fn nanoTime(self: Context) i128 {
    _ = self;
    return std.time.nanoTimestamp();
}

pub fn sleep(self: Context, ns: u64) void {
    _ = self;
    std.time.sleep(ns);
}

pub fn clipboardText(self: Context) ![]const u8 {
    const state = stateFromHwnd(hwndFromContext(self));
    const opened = win32.OpenClipboard(hwndFromContext(self)) == win32.zig.TRUE;
    defer _ = win32.CloseClipboard();
    if (!opened) {
        return "";
    }

    // istg, windows. why. why utf16.
    const data_handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse return "";

    var res: []u8 = undefined;
    {
        const handle: isize = @intCast(@intFromPtr(data_handle));
        const data: [*:0]u16 = @ptrCast(@alignCast(win32.GlobalLock(handle) orelse return ""));
        defer _ = win32.GlobalUnlock(handle);

        // we want this to be a sane format.
        const len = std.mem.indexOfSentinel(u16, 0, data);
        res = std.unicode.utf16LeToUtf8Alloc(state.arena, data[0..len]) catch return error.OutOfMemory;
    }

    return res;
}

pub fn clipboardTextSet(self: Context, text: []const u8) !void {
    const state = stateFromHwnd(hwndFromContext(self));
    const opened = win32.OpenClipboard(hwndFromContext(self)) == win32.zig.TRUE;
    defer _ = win32.CloseClipboard();
    if (!opened) {
        return;
    }

    const handle = win32.GlobalAlloc(win32.GMEM_MOVEABLE, text.len * @sizeOf(u16) + 1); // don't forget the nullbyte
    if (handle != 0x0) {
        const as_utf16 = std.unicode.utf8ToUtf16LeAlloc(state.arena, text) catch return error.OutOfMemory;
        defer state.arena.free(as_utf16);

        const data: [*:0]u16 = @ptrCast(@alignCast(win32.GlobalLock(handle) orelse return));
        defer _ = win32.GlobalUnlock(handle);

        for (as_utf16, 0..) |wide, i| {
            data[i] = wide;
        }
    } else {
        return error.OutOfMemory;
    }

    _ = win32.EmptyClipboard();
    const handle_usize: usize = @intCast(handle);
    _ = win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), @ptrFromInt(handle_usize));
}

pub fn openURL(self: Context, url: []const u8) !void {
    _ = self;
    _ = url;
}

pub fn refresh(self: Context) void {
    _ = self;
}

fn addEvent(self: Context, window: *dvui.Window, key_event: KeyEvent) !bool {
    _ = self;
    const event = key_event.target;
    const action = key_event.action;
    switch (event) {
        .keyboard_key => |ev| {
            return window.addEventKey(.{
                .code = ev,
                .action = if (action == .up) .up else .down,
                .mod = dvui.enums.Mod.none,
            });
        },
        .mouse_key => |ev| {
            return window.addEventMouseButton(ev, if (action == .up) .release else .press);
        },
        .mouse_event => |ev| {
            return window.addEventMouseMotion(@floatFromInt(ev.x), @floatFromInt(ev.y));
        },
        .wheel_event => |ev| {
            return window.addEventMouseWheel(@floatFromInt(ev), .vertical);
        },
        .none => return false,
    }
}

pub fn addAllEvents(self: Context, window: *dvui.Window) !bool {
    _ = self;
    _ = window;
    return false;
}

pub fn setCursor(self: Context, new_cursor: dvui.enums.Cursor) void {
    _ = self;
    const converted_cursor = switch (new_cursor) {
        .arrow => win32.IDC_ARROW,
        .ibeam => win32.IDC_IBEAM,
        .wait, .wait_arrow => win32.IDC_WAIT,
        .crosshair => win32.IDC_CROSS,
        .arrow_nw_se => win32.IDC_ARROW,
        .arrow_ne_sw => win32.IDC_ARROW,
        .arrow_w_e => win32.IDC_ARROW,
        .arrow_n_s => win32.IDC_ARROW,
        .arrow_all => win32.IDC_ARROW,
        .bad => win32.IDC_NO,
        .hand => win32.IDC_HAND,
    };

    _ = win32.LoadCursorW(null, converted_cursor);
}

fn hwndFromContext(ctx: Context) win32.HWND {
    return @ptrCast(ctx);
}
pub fn contextFromHwnd(hwnd: win32.HWND) Context {
    return @ptrCast(hwnd);
}
fn stateFromHwnd(hwnd: win32.HWND) *WindowState {
    const addr: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, @enumFromInt(0)));
    if (addr == 0) @panic("window is missing it's state!");
    return @ptrFromInt(addr);
}

pub fn attach(
    hwnd: win32.HWND,
    window_state: *WindowState,
    gpa: std.mem.Allocator,
    dx_options: Directx11Options,
    opt: struct { vsync: bool },
) !Context {
    var dvui_window = try dvui.Window.init(@src(), gpa, contextFromHwnd(hwnd).backend(), .{});
    errdefer dvui_window.deinit();
    window_state.* = .{
        .vsync = opt.vsync,
        .dvui_window = dvui_window,
        .device = dx_options.device,
        .device_context = dx_options.device_context,
        .swap_chain = dx_options.swap_chain,
    };
    {
        const existing = win32.SetWindowLongPtrW(
            hwnd,
            @enumFromInt(0),
            @bitCast(@intFromPtr(window_state)),
        );
        if (existing != 0) std.debug.panic("hwnd is already using slot 0 for something? (0x{x})", .{existing});
    }
    {
        const addr: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, @enumFromInt(0)));
        if (addr == 0) @panic("unable to attach window state pointer to HWND, did you set cbWndExtra to be >= to @sizeof(usize)?");
    }

    std.debug.assert(stateFromHwnd(hwnd) == window_state);
    return contextFromHwnd(hwnd);
}

// ############ Event Handling via wnd proc ############
pub fn wndProc(
    hwnd: win32.HWND,
    umsg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (umsg) {
        win32.WM_CREATE => {
            const create_struct: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const args: *CreateWindowArgs = @alignCast(@ptrCast(create_struct.lpCreateParams));
            const dx_options = createDeviceD3D(hwnd) orelse {
                args.err = error.D3dDeviceInitFailed;
                return -1;
            };
            errdefer dx_options.deinit();
            _ = attach(hwnd, args.window_state, args.dvui_gpa, dx_options, .{ .vsync = args.vsync }) catch |e| {
                args.err = e;
                return -1;
            };
            return 0;
        },
        win32.WM_DESTROY => {
            const state = stateFromHwnd(hwnd);
            state.deinit();
            return 0;
        },
        win32.WM_CLOSE => {
            // TODO: this should go through DVUI instead of posting WM_QUIT to the message loop
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            _ = win32.BeginPaint(hwnd, &ps) orelse return win32.panicWin32("BeginPaint", win32.GetLastError());
            defer if (0 == win32.EndPaint(hwnd, &ps)) win32.panicWin32("EndPaint", win32.GetLastError());
            return 0;
        },
        win32.WM_SIZE => {
            const size = win32.getClientSize(hwnd);
            //const resize: packed struct { width: i16, height: i16, _upper: i32 } = @bitCast(lparam);
            // instance.options.size.w = @floatFromInt(resize.width);
            // instance.options.size.h = @floatFromInt(resize.height);
            contextFromHwnd(hwnd).handleSwapChainResizing(@intCast(size.cx), @intCast(size.cy)) catch {
                log.err("Failed to handle swap chain resizing...", .{});
            };
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            if (std.meta.intToEnum(win32.VIRTUAL_KEY, wparam)) |as_vkey| {
                const conv_vkey = convertVKeyToDvuiKey(as_vkey);
                const state = stateFromHwnd(hwnd);
                const dk = DvuiKey{ .keyboard_key = conv_vkey };
                _ = contextFromHwnd(hwnd).addEvent(
                    &state.dvui_window,
                    KeyEvent{ .target = dk, .action = .down },
                ) catch {};
            } else |err| {
                log.err("invalid key found: {}", .{err});
            }
            return if (umsg == win32.WM_SYSKEYDOWN)
                win32.DefWindowProcW(hwnd, umsg, wparam, lparam)
            else
                0;
        },
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK => {
            const lbutton = dvui.enums.Button.left;
            const dk = DvuiKey{ .mouse_key = lbutton };
            const state = stateFromHwnd(hwnd);
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .down },
            ) catch {};
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            const rbutton = dvui.enums.Button.right;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = rbutton };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .down },
            ) catch {};
            return 0;
        },
        win32.WM_MBUTTONDOWN => {
            const mbutton = dvui.enums.Button.middle;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = mbutton };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .down },
            ) catch {};
            return 0;
        },
        win32.WM_XBUTTONDOWN => {
            const xbutton: packed struct { _upper: u16, which: u16, _lower: u32 } = @bitCast(wparam);
            const variant = if (xbutton.which == 1) dvui.enums.Button.four else dvui.enums.Button.five;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = variant };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .down },
            ) catch {};
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const lparam_low: i32 = @truncate(lparam);
            const bits: packed struct { x: i16, y: i16 } = @bitCast(lparam_low);
            const state = stateFromHwnd(hwnd);
            const mouse_x, const mouse_y = .{ bits.x, bits.y };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = DvuiKey{
                    .mouse_event = .{ .x = mouse_x, .y = mouse_y },
                }, .action = .down },
            ) catch {};
            return 0;
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            if (std.meta.intToEnum(win32.VIRTUAL_KEY, wparam)) |as_vkey| {
                const conv_vkey = convertVKeyToDvuiKey(as_vkey);
                const state = stateFromHwnd(hwnd);
                const dk = DvuiKey{ .keyboard_key = conv_vkey };
                _ = contextFromHwnd(hwnd).addEvent(
                    &state.dvui_window,
                    KeyEvent{ .target = dk, .action = .up },
                ) catch {};
            } else |err| {
                log.err("invalid key found: {}", .{err});
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const lbutton = dvui.enums.Button.left;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = lbutton };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .up },
            ) catch {};
            return 0;
        },
        win32.WM_RBUTTONUP => {
            const rbutton = dvui.enums.Button.right;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = rbutton };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .up },
            ) catch {};
            return 0;
        },
        win32.WM_MBUTTONUP => {
            const mbutton = dvui.enums.Button.middle;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = mbutton };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .up },
            ) catch {};
            return 0;
        },
        win32.WM_XBUTTONUP => {
            const xbutton: packed struct { _upper: u16, which: u16, _lower: u32 } = @bitCast(wparam);
            const variant = if (xbutton.which == 1) dvui.enums.Button.four else dvui.enums.Button.five;
            const state = stateFromHwnd(hwnd);
            const dk = DvuiKey{ .mouse_key = variant };
            _ = contextFromHwnd(hwnd).addEvent(
                &state.dvui_window,
                KeyEvent{ .target = dk, .action = .up },
            ) catch {};
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            const higher: isize = @intCast(wparam >> 16);
            const wheel_info: i16 = @truncate(higher);
            const state = stateFromHwnd(hwnd);
            _ = contextFromHwnd(hwnd).addEvent(&state.dvui_window, KeyEvent{
                .target = .{ .wheel_event = wheel_info },
                .action = .none,
            }) catch {};
            return 0;
        },
        win32.WM_CHAR => {
            const state = stateFromHwnd(hwnd);
            const ascii_char: u8 = @truncate(wparam);
            if (std.ascii.isPrint(ascii_char)) {
                const string: []const u8 = &.{ascii_char};
                _ = state.dvui_window.addEventText(string) catch {};
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, umsg, wparam, lparam),
    }
}

// ############ Utilities ############
fn convertSpaceToNDC(size: dvui.Size, x: f32, y: f32) XMFLOAT3 {
    return XMFLOAT3{
        .x = (2.0 * x / size.w) - 1.0,
        .y = 1.0 - (2.0 * y / size.h),
        .z = 0.0,
    };
}

fn convertVertices(
    arena: std.mem.Allocator,
    size: dvui.Size,
    vtx: []const dvui.Vertex,
    signal_invalid_uv: bool,
) ![]SimpleVertex {
    const simple_vertex = try arena.alloc(SimpleVertex, vtx.len);
    for (vtx, simple_vertex) |v, *s| {
        const r: f32 = @floatFromInt(v.col.r);
        const g: f32 = @floatFromInt(v.col.g);
        const b: f32 = @floatFromInt(v.col.b);
        const a: f32 = @floatFromInt(v.col.a);

        s.* = .{
            .position = convertSpaceToNDC(size, v.pos.x, v.pos.y),
            .color = .{ .r = r / 255.0, .g = g / 255.0, .b = b / 255.0, .a = a / 255.0 },
            .texcoord = if (signal_invalid_uv) .{ .x = -1.0, .y = -1.0 } else .{ .x = v.uv[0], .y = v.uv[1] },
        };
    }

    return simple_vertex;
}

const CreateWindowArgs = struct {
    window_state: *WindowState,
    vsync: bool,
    dvui_gpa: std.mem.Allocator,
    err: ?anyerror = null,
};

fn createDeviceD3D(hwnd: win32.HWND) ?Directx11Options {
    const client_size = win32.getClientSize(hwnd);

    var sd = std.mem.zeroes(win32.DXGI_SWAP_CHAIN_DESC);
    sd.BufferCount = 6;
    sd.BufferDesc.Width = @intCast(client_size.cx);
    sd.BufferDesc.Height = @intCast(client_size.cy);
    sd.BufferDesc.Format = win32.DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.Flags = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH);
    sd.BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    @setRuntimeSafety(false);
    sd.OutputWindow = hwnd;
    @setRuntimeSafety(true);
    sd.SampleDesc.Count = 1;
    sd.SampleDesc.Quality = 0;
    sd.Windowed = 1;
    sd.SwapEffect = win32.DXGI_SWAP_EFFECT_DISCARD;

    const createDeviceFlags: win32.D3D11_CREATE_DEVICE_FLAG = .{
        .DEBUG = 0,
    };
    //createDeviceFlags |= D3D11_CREATE_DEVICE_DEBUG;
    var featureLevel: win32.D3D_FEATURE_LEVEL = undefined;
    const featureLevelArray = &[_]win32.D3D_FEATURE_LEVEL{ win32.D3D_FEATURE_LEVEL_11_0, win32.D3D_FEATURE_LEVEL_10_0 };

    var device: *win32.ID3D11Device = undefined;
    var device_context: *win32.ID3D11DeviceContext = undefined;
    var swap_chain: *win32.IDXGISwapChain = undefined;

    var res: win32.HRESULT = win32.D3D11CreateDeviceAndSwapChain(
        null,
        win32.D3D_DRIVER_TYPE_HARDWARE,
        null,
        createDeviceFlags,
        featureLevelArray,
        2,
        win32.D3D11_SDK_VERSION,
        &sd,
        &swap_chain,
        &device,
        &featureLevel,
        &device_context,
    );

    if (res == win32.DXGI_ERROR_UNSUPPORTED) {
        res = win32.D3D11CreateDeviceAndSwapChain(
            null,
            win32.D3D_DRIVER_TYPE_WARP,
            null,
            createDeviceFlags,
            featureLevelArray,
            2,
            win32.D3D11_SDK_VERSION,
            &sd,
            &swap_chain,
            &device,
            &featureLevel,
            &device_context,
        );
    }
    if (!isOk(res))
        return null;

    return Directx11Options{
        .device = device,
        .device_context = device_context,
        .swap_chain = swap_chain,
    };
}

fn convertVKeyToDvuiKey(vkey: win32.VIRTUAL_KEY) dvui.enums.Key {
    const K = dvui.enums.Key;
    return switch (vkey) {
        .@"0", .NUMPAD0 => K.kp_0,
        .@"1", .NUMPAD1 => K.kp_1,
        .@"2", .NUMPAD2 => K.kp_2,
        .@"3", .NUMPAD3 => K.kp_3,
        .@"4", .NUMPAD4 => K.kp_4,
        .@"5", .NUMPAD5 => K.kp_5,
        .@"6", .NUMPAD6 => K.kp_6,
        .@"7", .NUMPAD7 => K.kp_7,
        .@"8", .NUMPAD8 => K.kp_8,
        .@"9", .NUMPAD9 => K.kp_9,
        .A => K.a,
        .B => K.b,
        .C => K.c,
        .D => K.d,
        .E => K.e,
        .F => K.f,
        .G => K.g,
        .H => K.h,
        .I => K.i,
        .J => K.j,
        .K => K.k,
        .L => K.l,
        .M => K.m,
        .N => K.n,
        .O => K.o,
        .P => K.p,
        .Q => K.q,
        .R => K.r,
        .S => K.s,
        .T => K.t,
        .U => K.u,
        .V => K.v,
        .W => K.w,
        .X => K.x,
        .Y => K.y,
        .Z => K.z,
        .BACK => K.backspace,
        .TAB => K.tab,
        .RETURN => K.enter,
        .F1 => K.f1,
        .F2 => K.f2,
        .F3 => K.f3,
        .F4 => K.f4,
        .F5 => K.f5,
        .F6 => K.f6,
        .F7 => K.f7,
        .F8 => K.f8,
        .F9 => K.f9,
        .F10 => K.f10,
        .F11 => K.f11,
        .F12 => K.f12,
        .F13 => K.f13,
        .F14 => K.f14,
        .F15 => K.f15,
        .F16 => K.f16,
        .F17 => K.f17,
        .F18 => K.f18,
        .F19 => K.f19,
        .F20 => K.f20,
        .F21 => K.f21,
        .F22 => K.f22,
        .F23 => K.f23,
        .F24 => K.f24,
        .SHIFT, .LSHIFT => K.left_shift,
        .RSHIFT => K.right_shift,
        .CONTROL, .LCONTROL => K.left_control,
        .RCONTROL => K.right_control,
        .MENU => K.menu,
        .PAUSE => K.pause,
        .ESCAPE => K.escape,
        .SPACE => K.space,
        .END => K.end,
        .HOME => K.home,
        .LEFT => K.left,
        .RIGHT => K.right,
        .UP => K.up,
        .DOWN => K.down,
        .PRINT => K.print,
        .INSERT => K.insert,
        .DELETE => K.delete,
        .LWIN => K.left_command,
        .RWIN => K.right_command,
        .PRIOR => K.page_up,
        .NEXT => K.page_down,
        .MULTIPLY => K.kp_multiply,
        .ADD => K.kp_add,
        .SUBTRACT => K.kp_subtract,
        .DIVIDE => K.kp_divide,
        .NUMLOCK => K.num_lock,
        .OEM_1 => K.semicolon,
        .OEM_2 => K.slash,
        .OEM_3 => K.grave,
        .OEM_4 => K.left_bracket,
        .OEM_5 => K.backslash,
        .OEM_6 => K.right_bracket,
        .OEM_7 => K.apostrophe,
        .CAPITAL => K.caps_lock,
        .OEM_PLUS => K.kp_equal,
        .OEM_MINUS => K.minus,
        else => |e| {
            log.warn("Key {s} not supported.", .{@tagName(e)});
            return K.unknown;
        },
    };
}
