//! Draws decoded YUV pictures with wgpu inside egui: Y and chroma planes as textures, converted to
//! RGB (BT.709, limited or full range) in the fragment shader.

use crate::decode::{Format, Shared};
use eframe::egui_wgpu::{self, wgpu, CallbackTrait};
use std::sync::{Arc, Mutex};

const SHADER: &str = r#"
struct U { fmt: u32, full: u32, a: u32, b: u32, crop: vec4<f32> };
@group(0) @binding(0) var ty: texture_2d<f32>;
@group(0) @binding(1) var t1: texture_2d<f32>;
@group(0) @binding(2) var t2: texture_2d<f32>;
@group(0) @binding(3) var smp: sampler;
@group(0) @binding(4) var<uniform> u: U;
struct VO { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> VO {
    var p = array<vec2<f32>, 3>(vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
    var o: VO;
    o.pos = vec4(p[i], 0.0, 1.0);
    let t = vec2((p[i].x + 1.0) * 0.5, 1.0 - (p[i].y + 1.0) * 0.5);
    o.uv = u.crop.xy + t * (u.crop.zw - u.crop.xy);   // the part of the picture on screen (zoom)
    return o;
}
@fragment fn fs(v: VO) -> @location(0) vec4<f32> {
    let y = textureSample(ty, smp, v.uv).r;
    let c1 = textureSample(t1, smp, v.uv);
    let c2 = textureSample(t2, smp, v.uv);
    var cb = c1.r;
    var cr = c2.r;
    if (u.fmt == 0u) { cb = c1.r; cr = c1.g; }
    var Y = y;
    var Cb = cb - 0.5;
    var Cr = cr - 0.5;
    if (u.full == 0u) {
        Y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        Cb = Cb * (255.0 / 224.0);
        Cr = Cr * (255.0 / 224.0);
    }
    let r = Y + 1.5748 * Cr;
    let g = Y - 0.1873 * Cb - 0.4681 * Cr;
    let b = Y + 1.8556 * Cb;
    return vec4(clamp(vec3(r, g, b), vec3(0.0), vec3(1.0)), 1.0);
}
"#;

struct Planes {
    w: u32,
    h: u32,
    format: Format,
    tex: [wgpu::Texture; 3],
}

pub struct Resources {
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    uniform: wgpu::Buffer,
    planes: Option<Planes>,
    bind: Option<wgpu::BindGroup>,
}

pub fn init(rs: &egui_wgpu::RenderState) {
    let device = &rs.device;
    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("yuv"),
        source: wgpu::ShaderSource::Wgsl(SHADER.into()),
    });
    let tex_entry = |binding| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    };
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("yuv"),
        entries: &[
            tex_entry(0), tex_entry(1), tex_entry(2),
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 4,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,   // the vertex stage reads the crop
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
        ],
    });
    let pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("yuv"),
        bind_group_layouts: &[&layout],
        push_constant_ranges: &[],
    });
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("yuv"),
        layout: Some(&pl),
        vertex: wgpu::VertexState { module: &module, entry_point: "vs", buffers: &[], compilation_options: Default::default() },
        fragment: Some(wgpu::FragmentState {
            module: &module,
            entry_point: "fs",
            targets: &[Some(rs.target_format.into())],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: None,
        multisample: wgpu::MultisampleState::default(),
        multiview: None,
        cache: None,
    });
    let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        ..Default::default()
    });
    let uniform = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("yuv"),
        size: 32,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    rs.renderer.write().callback_resources.insert(Resources { pipeline, layout, sampler, uniform, planes: None, bind: None });
}

fn texture(device: &wgpu::Device, w: u32, h: u32, format: wgpu::TextureFormat) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some("plane"),
        size: wgpu::Extent3d { width: w.max(1), height: h.max(1), depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    })
}

fn upload(queue: &wgpu::Queue, tex: &wgpu::Texture, data: &[u8], w: u32, h: u32, bpp: u32) {
    queue.write_texture(
        wgpu::ImageCopyTexture { texture: tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        data,
        wgpu::ImageDataLayout { offset: 0, bytes_per_row: Some(w * bpp), rows_per_image: Some(h) },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );
}

pub struct VideoCallback {
    pub shared: Arc<Mutex<Shared>>,
    /// The part of the picture to draw, as (u0, v0, u1, v1) in 0..1: all of it, or the zoomed part.
    pub crop: [f32; 4],
}

impl CallbackTrait for VideoCallback {
    fn prepare(&self, device: &wgpu::Device, queue: &wgpu::Queue, _sd: &egui_wgpu::ScreenDescriptor,
               _enc: &mut wgpu::CommandEncoder, res: &mut egui_wgpu::CallbackResources) -> Vec<wgpu::CommandBuffer> {
        if let Some(r) = res.get::<Resources>() {
            queue.write_buffer(&r.uniform, 16, bytemuck::cast_slice(&self.crop));
        }
        let Some(pic) = self.shared.lock().unwrap().latest.take() else { return Vec::new() };
        let Some(r) = res.get_mut::<Resources>() else { return Vec::new() };
        let (cw, ch) = ((pic.width + 1) / 2, (pic.height + 1) / 2);
        let fresh = !matches!(&r.planes, Some(p) if p.w == pic.width && p.h == pic.height && p.format == pic.format);
        if fresh {
            let tex = match pic.format {
                Format::Nv12 => [texture(device, pic.width, pic.height, wgpu::TextureFormat::R8Unorm),
                                 texture(device, cw, ch, wgpu::TextureFormat::Rg8Unorm),
                                 texture(device, 1, 1, wgpu::TextureFormat::R8Unorm)],
                Format::I420 => [texture(device, pic.width, pic.height, wgpu::TextureFormat::R8Unorm),
                                 texture(device, cw, ch, wgpu::TextureFormat::R8Unorm),
                                 texture(device, cw, ch, wgpu::TextureFormat::R8Unorm)],
            };
            let views: Vec<_> = tex.iter().map(|t| t.create_view(&Default::default())).collect();
            r.bind = Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("yuv"),
                layout: &r.layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&views[0]) },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&views[1]) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&views[2]) },
                    wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&r.sampler) },
                    wgpu::BindGroupEntry { binding: 4, resource: r.uniform.as_entire_binding() },
                ],
            }));
            r.planes = Some(Planes { w: pic.width, h: pic.height, format: pic.format, tex });
        }
        let p = r.planes.as_ref().unwrap();
        upload(queue, &p.tex[0], &pic.planes[0], pic.width, pic.height, 1);
        match pic.format {
            Format::Nv12 => upload(queue, &p.tex[1], &pic.planes[1], cw, ch, 2),
            Format::I420 => {
                upload(queue, &p.tex[1], &pic.planes[1], cw, ch, 1);
                upload(queue, &p.tex[2], &pic.planes[2], cw, ch, 1);
            }
        }
        let u: [u32; 4] = [if pic.format == Format::Nv12 { 0 } else { 1 }, pic.full_range as u32, 0, 0];
        queue.write_buffer(&r.uniform, 0, bytemuck::cast_slice(&u));
        Vec::new()
    }

    fn paint(&self, _info: eframe::egui::PaintCallbackInfo, pass: &mut wgpu::RenderPass<'static>,
             res: &egui_wgpu::CallbackResources) {
        let Some(r) = res.get::<Resources>() else { return };
        let Some(bind) = &r.bind else { return };
        pass.set_pipeline(&r.pipeline);
        pass.set_bind_group(0, bind, &[]);
        pass.draw(0..3, 0..1);
    }
}
