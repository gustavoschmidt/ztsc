
/**
 * The **`WebGLActiveInfo`** interface is part of the WebGL API and represents the information returned by calling the WebGLRenderingContext.getActiveAttrib() and WebGLRenderingContext.getActiveUniform() methods.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLActiveInfo)
 */
interface WebGLActiveInfo {
    /**
     * The read-only **`WebGLActiveInfo.name`** property represents the name of the requested data returned by calling the getActiveAttrib() or getActiveUniform() methods.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLActiveInfo/name)
     */
    readonly name: string;
    /**
     * The read-only **`WebGLActiveInfo.size`** property is a Number representing the size of the requested data returned by calling the getActiveAttrib() or getActiveUniform() methods.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLActiveInfo/size)
     */
    readonly size: GLint;
    /**
     * The read-only **`WebGLActiveInfo.type`** property represents the type of the requested data returned by calling the getActiveAttrib() or getActiveUniform() methods.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLActiveInfo/type)
     */
    readonly type: GLenum;
}

declare var WebGLActiveInfo: {
    prototype: WebGLActiveInfo;
    new(): WebGLActiveInfo;
};

/**
 * The **`WebGLBuffer`** interface is part of the WebGL API and represents an opaque buffer object storing data such as vertices or colors.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLBuffer)
 */
interface WebGLBuffer {
}

declare var WebGLBuffer: {
    prototype: WebGLBuffer;
    new(): WebGLBuffer;
};

/**
 * The **`WebGLContextEvent`** interface is part of the WebGL API and is an interface for an event that is generated in response to a status change to the WebGL rendering context.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLContextEvent)
 */
interface WebGLContextEvent extends Event {
    /**
     * The read-only **`WebGLContextEvent.statusMessage`** property contains additional event status information, or is an empty string if no additional information is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLContextEvent/statusMessage)
     */
    readonly statusMessage: string;
}

declare var WebGLContextEvent: {
    prototype: WebGLContextEvent;
    new(type: string, eventInit?: WebGLContextEventInit): WebGLContextEvent;
};

/**
 * The **`WebGLFramebuffer`** interface is part of the WebGL API and represents a collection of buffers that serve as a rendering destination.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLFramebuffer)
 */
interface WebGLFramebuffer {
}

declare var WebGLFramebuffer: {
    prototype: WebGLFramebuffer;
    new(): WebGLFramebuffer;
};

/**
 * The **`WebGLProgram`** is part of the WebGL API and is a combination of two compiled WebGLShaders consisting of a vertex shader and a fragment shader (both written in GLSL).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLProgram)
 */
interface WebGLProgram {
}

declare var WebGLProgram: {
    prototype: WebGLProgram;
    new(): WebGLProgram;
};

/**
 * The **`WebGLQuery`** interface is part of the WebGL 2 API and provides ways to asynchronously query for information. By default, occlusion queries and primitive queries are available.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLQuery)
 */
interface WebGLQuery {
}

declare var WebGLQuery: {
    prototype: WebGLQuery;
    new(): WebGLQuery;
};

/**
 * The **`WebGLRenderbuffer`** interface is part of the WebGL API and represents a buffer that can contain an image, or that can be a source or target of a rendering operation.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderbuffer)
 */
interface WebGLRenderbuffer {
}

declare var WebGLRenderbuffer: {
    prototype: WebGLRenderbuffer;
    new(): WebGLRenderbuffer;
};

/**
 * The **`WebGLRenderingContext`** interface provides an interface to the OpenGL ES 2.0 graphics rendering context for the drawing surface of an HTML <canvas> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext)
 */
interface WebGLRenderingContext extends WebGLRenderingContextBase, WebGLRenderingContextOverloads {
}

declare var WebGLRenderingContext: {
    prototype: WebGLRenderingContext;
    new(): WebGLRenderingContext;
    readonly DEPTH_BUFFER_BIT: 0x00000100;
    readonly STENCIL_BUFFER_BIT: 0x00000400;
    readonly COLOR_BUFFER_BIT: 0x00004000;
    readonly POINTS: 0x0000;
    readonly LINES: 0x0001;
    readonly LINE_LOOP: 0x0002;
    readonly LINE_STRIP: 0x0003;
    readonly TRIANGLES: 0x0004;
    readonly TRIANGLE_STRIP: 0x0005;
    readonly TRIANGLE_FAN: 0x0006;
    readonly ZERO: 0;
    readonly ONE: 1;
    readonly SRC_COLOR: 0x0300;
    readonly ONE_MINUS_SRC_COLOR: 0x0301;
    readonly SRC_ALPHA: 0x0302;
    readonly ONE_MINUS_SRC_ALPHA: 0x0303;
    readonly DST_ALPHA: 0x0304;
    readonly ONE_MINUS_DST_ALPHA: 0x0305;
    readonly DST_COLOR: 0x0306;
    readonly ONE_MINUS_DST_COLOR: 0x0307;
    readonly SRC_ALPHA_SATURATE: 0x0308;
    readonly FUNC_ADD: 0x8006;
    readonly BLEND_EQUATION: 0x8009;
    readonly BLEND_EQUATION_RGB: 0x8009;
    readonly BLEND_EQUATION_ALPHA: 0x883D;
    readonly FUNC_SUBTRACT: 0x800A;
    readonly FUNC_REVERSE_SUBTRACT: 0x800B;
    readonly BLEND_DST_RGB: 0x80C8;
    readonly BLEND_SRC_RGB: 0x80C9;
    readonly BLEND_DST_ALPHA: 0x80CA;
    readonly BLEND_SRC_ALPHA: 0x80CB;
    readonly CONSTANT_COLOR: 0x8001;
    readonly ONE_MINUS_CONSTANT_COLOR: 0x8002;
    readonly CONSTANT_ALPHA: 0x8003;
    readonly ONE_MINUS_CONSTANT_ALPHA: 0x8004;
    readonly BLEND_COLOR: 0x8005;
    readonly ARRAY_BUFFER: 0x8892;
    readonly ELEMENT_ARRAY_BUFFER: 0x8893;
    readonly ARRAY_BUFFER_BINDING: 0x8894;
    readonly ELEMENT_ARRAY_BUFFER_BINDING: 0x8895;
    readonly STREAM_DRAW: 0x88E0;
    readonly STATIC_DRAW: 0x88E4;
    readonly DYNAMIC_DRAW: 0x88E8;
    readonly BUFFER_SIZE: 0x8764;
    readonly BUFFER_USAGE: 0x8765;
    readonly CURRENT_VERTEX_ATTRIB: 0x8626;
    readonly FRONT: 0x0404;
    readonly BACK: 0x0405;
    readonly FRONT_AND_BACK: 0x0408;
    readonly CULL_FACE: 0x0B44;
    readonly BLEND: 0x0BE2;
    readonly DITHER: 0x0BD0;
    readonly STENCIL_TEST: 0x0B90;
    readonly DEPTH_TEST: 0x0B71;
    readonly SCISSOR_TEST: 0x0C11;
    readonly POLYGON_OFFSET_FILL: 0x8037;
    readonly SAMPLE_ALPHA_TO_COVERAGE: 0x809E;
    readonly SAMPLE_COVERAGE: 0x80A0;
    readonly NO_ERROR: 0;
    readonly INVALID_ENUM: 0x0500;
    readonly INVALID_VALUE: 0x0501;
    readonly INVALID_OPERATION: 0x0502;
    readonly OUT_OF_MEMORY: 0x0505;
    readonly CW: 0x0900;
    readonly CCW: 0x0901;
    readonly LINE_WIDTH: 0x0B21;
    readonly ALIASED_POINT_SIZE_RANGE: 0x846D;
    readonly ALIASED_LINE_WIDTH_RANGE: 0x846E;
    readonly CULL_FACE_MODE: 0x0B45;
    readonly FRONT_FACE: 0x0B46;
    readonly DEPTH_RANGE: 0x0B70;
    readonly DEPTH_WRITEMASK: 0x0B72;
    readonly DEPTH_CLEAR_VALUE: 0x0B73;
    readonly DEPTH_FUNC: 0x0B74;
    readonly STENCIL_CLEAR_VALUE: 0x0B91;
    readonly STENCIL_FUNC: 0x0B92;
    readonly STENCIL_FAIL: 0x0B94;
    readonly STENCIL_PASS_DEPTH_FAIL: 0x0B95;
    readonly STENCIL_PASS_DEPTH_PASS: 0x0B96;
    readonly STENCIL_REF: 0x0B97;
    readonly STENCIL_VALUE_MASK: 0x0B93;
    readonly STENCIL_WRITEMASK: 0x0B98;
    readonly STENCIL_BACK_FUNC: 0x8800;
    readonly STENCIL_BACK_FAIL: 0x8801;
    readonly STENCIL_BACK_PASS_DEPTH_FAIL: 0x8802;
    readonly STENCIL_BACK_PASS_DEPTH_PASS: 0x8803;
    readonly STENCIL_BACK_REF: 0x8CA3;
    readonly STENCIL_BACK_VALUE_MASK: 0x8CA4;
    readonly STENCIL_BACK_WRITEMASK: 0x8CA5;
    readonly VIEWPORT: 0x0BA2;
    readonly SCISSOR_BOX: 0x0C10;
    readonly COLOR_CLEAR_VALUE: 0x0C22;
    readonly COLOR_WRITEMASK: 0x0C23;
    readonly UNPACK_ALIGNMENT: 0x0CF5;
    readonly PACK_ALIGNMENT: 0x0D05;
    readonly MAX_TEXTURE_SIZE: 0x0D33;
    readonly MAX_VIEWPORT_DIMS: 0x0D3A;
    readonly SUBPIXEL_BITS: 0x0D50;
    readonly RED_BITS: 0x0D52;
    readonly GREEN_BITS: 0x0D53;
    readonly BLUE_BITS: 0x0D54;
    readonly ALPHA_BITS: 0x0D55;
    readonly DEPTH_BITS: 0x0D56;
    readonly STENCIL_BITS: 0x0D57;
    readonly POLYGON_OFFSET_UNITS: 0x2A00;
    readonly POLYGON_OFFSET_FACTOR: 0x8038;
    readonly TEXTURE_BINDING_2D: 0x8069;
    readonly SAMPLE_BUFFERS: 0x80A8;
    readonly SAMPLES: 0x80A9;
    readonly SAMPLE_COVERAGE_VALUE: 0x80AA;
    readonly SAMPLE_COVERAGE_INVERT: 0x80AB;
    readonly COMPRESSED_TEXTURE_FORMATS: 0x86A3;
    readonly DONT_CARE: 0x1100;
    readonly FASTEST: 0x1101;
    readonly NICEST: 0x1102;
    readonly GENERATE_MIPMAP_HINT: 0x8192;
    readonly BYTE: 0x1400;
    readonly UNSIGNED_BYTE: 0x1401;
    readonly SHORT: 0x1402;
    readonly UNSIGNED_SHORT: 0x1403;
    readonly INT: 0x1404;
    readonly UNSIGNED_INT: 0x1405;
    readonly FLOAT: 0x1406;
    readonly DEPTH_COMPONENT: 0x1902;
    readonly ALPHA: 0x1906;
    readonly RGB: 0x1907;
    readonly RGBA: 0x1908;
    readonly LUMINANCE: 0x1909;
    readonly LUMINANCE_ALPHA: 0x190A;
    readonly UNSIGNED_SHORT_4_4_4_4: 0x8033;
    readonly UNSIGNED_SHORT_5_5_5_1: 0x8034;
    readonly UNSIGNED_SHORT_5_6_5: 0x8363;
    readonly FRAGMENT_SHADER: 0x8B30;
    readonly VERTEX_SHADER: 0x8B31;
    readonly MAX_VERTEX_ATTRIBS: 0x8869;
    readonly MAX_VERTEX_UNIFORM_VECTORS: 0x8DFB;
    readonly MAX_VARYING_VECTORS: 0x8DFC;
    readonly MAX_COMBINED_TEXTURE_IMAGE_UNITS: 0x8B4D;
    readonly MAX_VERTEX_TEXTURE_IMAGE_UNITS: 0x8B4C;
    readonly MAX_TEXTURE_IMAGE_UNITS: 0x8872;
    readonly MAX_FRAGMENT_UNIFORM_VECTORS: 0x8DFD;
    readonly SHADER_TYPE: 0x8B4F;
    readonly DELETE_STATUS: 0x8B80;
    readonly LINK_STATUS: 0x8B82;
    readonly VALIDATE_STATUS: 0x8B83;
    readonly ATTACHED_SHADERS: 0x8B85;
    readonly ACTIVE_UNIFORMS: 0x8B86;
    readonly ACTIVE_ATTRIBUTES: 0x8B89;
    readonly SHADING_LANGUAGE_VERSION: 0x8B8C;
    readonly CURRENT_PROGRAM: 0x8B8D;
    readonly NEVER: 0x0200;
    readonly LESS: 0x0201;
    readonly EQUAL: 0x0202;
    readonly LEQUAL: 0x0203;
    readonly GREATER: 0x0204;
    readonly NOTEQUAL: 0x0205;
    readonly GEQUAL: 0x0206;
    readonly ALWAYS: 0x0207;
    readonly KEEP: 0x1E00;
    readonly REPLACE: 0x1E01;
    readonly INCR: 0x1E02;
    readonly DECR: 0x1E03;
    readonly INVERT: 0x150A;
    readonly INCR_WRAP: 0x8507;
    readonly DECR_WRAP: 0x8508;
    readonly VENDOR: 0x1F00;
    readonly RENDERER: 0x1F01;
    readonly VERSION: 0x1F02;
    readonly NEAREST: 0x2600;
    readonly LINEAR: 0x2601;
    readonly NEAREST_MIPMAP_NEAREST: 0x2700;
    readonly LINEAR_MIPMAP_NEAREST: 0x2701;
    readonly NEAREST_MIPMAP_LINEAR: 0x2702;
    readonly LINEAR_MIPMAP_LINEAR: 0x2703;
    readonly TEXTURE_MAG_FILTER: 0x2800;
    readonly TEXTURE_MIN_FILTER: 0x2801;
    readonly TEXTURE_WRAP_S: 0x2802;
    readonly TEXTURE_WRAP_T: 0x2803;
    readonly TEXTURE_2D: 0x0DE1;
    readonly TEXTURE: 0x1702;
    readonly TEXTURE_CUBE_MAP: 0x8513;
    readonly TEXTURE_BINDING_CUBE_MAP: 0x8514;
    readonly TEXTURE_CUBE_MAP_POSITIVE_X: 0x8515;
    readonly TEXTURE_CUBE_MAP_NEGATIVE_X: 0x8516;
    readonly TEXTURE_CUBE_MAP_POSITIVE_Y: 0x8517;
    readonly TEXTURE_CUBE_MAP_NEGATIVE_Y: 0x8518;
    readonly TEXTURE_CUBE_MAP_POSITIVE_Z: 0x8519;
    readonly TEXTURE_CUBE_MAP_NEGATIVE_Z: 0x851A;
    readonly MAX_CUBE_MAP_TEXTURE_SIZE: 0x851C;
    readonly TEXTURE0: 0x84C0;
    readonly TEXTURE1: 0x84C1;
    readonly TEXTURE2: 0x84C2;
    readonly TEXTURE3: 0x84C3;
    readonly TEXTURE4: 0x84C4;
    readonly TEXTURE5: 0x84C5;
    readonly TEXTURE6: 0x84C6;
    readonly TEXTURE7: 0x84C7;
    readonly TEXTURE8: 0x84C8;
    readonly TEXTURE9: 0x84C9;
    readonly TEXTURE10: 0x84CA;
    readonly TEXTURE11: 0x84CB;
    readonly TEXTURE12: 0x84CC;
    readonly TEXTURE13: 0x84CD;
    readonly TEXTURE14: 0x84CE;
    readonly TEXTURE15: 0x84CF;
    readonly TEXTURE16: 0x84D0;
    readonly TEXTURE17: 0x84D1;
    readonly TEXTURE18: 0x84D2;
    readonly TEXTURE19: 0x84D3;
    readonly TEXTURE20: 0x84D4;
    readonly TEXTURE21: 0x84D5;
    readonly TEXTURE22: 0x84D6;
    readonly TEXTURE23: 0x84D7;
    readonly TEXTURE24: 0x84D8;
    readonly TEXTURE25: 0x84D9;
    readonly TEXTURE26: 0x84DA;
    readonly TEXTURE27: 0x84DB;
    readonly TEXTURE28: 0x84DC;
    readonly TEXTURE29: 0x84DD;
    readonly TEXTURE30: 0x84DE;
    readonly TEXTURE31: 0x84DF;
    readonly ACTIVE_TEXTURE: 0x84E0;
    readonly REPEAT: 0x2901;
    readonly CLAMP_TO_EDGE: 0x812F;
    readonly MIRRORED_REPEAT: 0x8370;
    readonly FLOAT_VEC2: 0x8B50;
    readonly FLOAT_VEC3: 0x8B51;
    readonly FLOAT_VEC4: 0x8B52;
    readonly INT_VEC2: 0x8B53;
    readonly INT_VEC3: 0x8B54;
    readonly INT_VEC4: 0x8B55;
    readonly BOOL: 0x8B56;
    readonly BOOL_VEC2: 0x8B57;
    readonly BOOL_VEC3: 0x8B58;
    readonly BOOL_VEC4: 0x8B59;
    readonly FLOAT_MAT2: 0x8B5A;
    readonly FLOAT_MAT3: 0x8B5B;
    readonly FLOAT_MAT4: 0x8B5C;
    readonly SAMPLER_2D: 0x8B5E;
    readonly SAMPLER_CUBE: 0x8B60;
    readonly VERTEX_ATTRIB_ARRAY_ENABLED: 0x8622;
    readonly VERTEX_ATTRIB_ARRAY_SIZE: 0x8623;
    readonly VERTEX_ATTRIB_ARRAY_STRIDE: 0x8624;
    readonly VERTEX_ATTRIB_ARRAY_TYPE: 0x8625;
    readonly VERTEX_ATTRIB_ARRAY_NORMALIZED: 0x886A;
    readonly VERTEX_ATTRIB_ARRAY_POINTER: 0x8645;
    readonly VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: 0x889F;
    readonly IMPLEMENTATION_COLOR_READ_TYPE: 0x8B9A;
    readonly IMPLEMENTATION_COLOR_READ_FORMAT: 0x8B9B;
    readonly COMPILE_STATUS: 0x8B81;
    readonly LOW_FLOAT: 0x8DF0;
    readonly MEDIUM_FLOAT: 0x8DF1;
    readonly HIGH_FLOAT: 0x8DF2;
    readonly LOW_INT: 0x8DF3;
    readonly MEDIUM_INT: 0x8DF4;
    readonly HIGH_INT: 0x8DF5;
    readonly FRAMEBUFFER: 0x8D40;
    readonly RENDERBUFFER: 0x8D41;
    readonly RGBA4: 0x8056;
    readonly RGB5_A1: 0x8057;
    readonly RGBA8: 0x8058;
    readonly RGB565: 0x8D62;
    readonly DEPTH_COMPONENT16: 0x81A5;
    readonly STENCIL_INDEX8: 0x8D48;
    readonly DEPTH_STENCIL: 0x84F9;
    readonly RENDERBUFFER_WIDTH: 0x8D42;
    readonly RENDERBUFFER_HEIGHT: 0x8D43;
    readonly RENDERBUFFER_INTERNAL_FORMAT: 0x8D44;
    readonly RENDERBUFFER_RED_SIZE: 0x8D50;
    readonly RENDERBUFFER_GREEN_SIZE: 0x8D51;
    readonly RENDERBUFFER_BLUE_SIZE: 0x8D52;
    readonly RENDERBUFFER_ALPHA_SIZE: 0x8D53;
    readonly RENDERBUFFER_DEPTH_SIZE: 0x8D54;
    readonly RENDERBUFFER_STENCIL_SIZE: 0x8D55;
    readonly FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: 0x8CD0;
    readonly FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: 0x8CD1;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: 0x8CD2;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE: 0x8CD3;
    readonly COLOR_ATTACHMENT0: 0x8CE0;
    readonly DEPTH_ATTACHMENT: 0x8D00;
    readonly STENCIL_ATTACHMENT: 0x8D20;
    readonly DEPTH_STENCIL_ATTACHMENT: 0x821A;
    readonly NONE: 0;
    readonly FRAMEBUFFER_COMPLETE: 0x8CD5;
    readonly FRAMEBUFFER_INCOMPLETE_ATTACHMENT: 0x8CD6;
    readonly FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT: 0x8CD7;
    readonly FRAMEBUFFER_INCOMPLETE_DIMENSIONS: 0x8CD9;
    readonly FRAMEBUFFER_UNSUPPORTED: 0x8CDD;
    readonly FRAMEBUFFER_BINDING: 0x8CA6;
    readonly RENDERBUFFER_BINDING: 0x8CA7;
    readonly MAX_RENDERBUFFER_SIZE: 0x84E8;
    readonly INVALID_FRAMEBUFFER_OPERATION: 0x0506;
    readonly UNPACK_FLIP_Y_WEBGL: 0x9240;
    readonly UNPACK_PREMULTIPLY_ALPHA_WEBGL: 0x9241;
    readonly CONTEXT_LOST_WEBGL: 0x9242;
    readonly UNPACK_COLORSPACE_CONVERSION_WEBGL: 0x9243;
    readonly BROWSER_DEFAULT_WEBGL: 0x9244;
};

interface WebGLRenderingContextBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/canvas) */
    readonly canvas: HTMLCanvasElement | OffscreenCanvas;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/drawingBufferColorSpace) */
    drawingBufferColorSpace: PredefinedColorSpace;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/drawingBufferHeight) */
    readonly drawingBufferHeight: GLsizei;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/drawingBufferWidth) */
    readonly drawingBufferWidth: GLsizei;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/unpackColorSpace) */
    unpackColorSpace: PredefinedColorSpace;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/activeTexture) */
    activeTexture(texture: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/attachShader) */
    attachShader(program: WebGLProgram, shader: WebGLShader): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bindAttribLocation) */
    bindAttribLocation(program: WebGLProgram, index: GLuint, name: string): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bindBuffer) */
    bindBuffer(target: GLenum, buffer: WebGLBuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bindFramebuffer) */
    bindFramebuffer(target: GLenum, framebuffer: WebGLFramebuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bindRenderbuffer) */
    bindRenderbuffer(target: GLenum, renderbuffer: WebGLRenderbuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bindTexture) */
    bindTexture(target: GLenum, texture: WebGLTexture | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/blendColor) */
    blendColor(red: GLclampf, green: GLclampf, blue: GLclampf, alpha: GLclampf): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/blendEquation) */
    blendEquation(mode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/blendEquationSeparate) */
    blendEquationSeparate(modeRGB: GLenum, modeAlpha: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/blendFunc) */
    blendFunc(sfactor: GLenum, dfactor: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/blendFuncSeparate) */
    blendFuncSeparate(srcRGB: GLenum, dstRGB: GLenum, srcAlpha: GLenum, dstAlpha: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/checkFramebufferStatus) */
    checkFramebufferStatus(target: GLenum): GLenum;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/clear) */
    clear(mask: GLbitfield): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/clearColor) */
    clearColor(red: GLclampf, green: GLclampf, blue: GLclampf, alpha: GLclampf): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/clearDepth) */
    clearDepth(depth: GLclampf): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/clearStencil) */
    clearStencil(s: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/colorMask) */
    colorMask(red: GLboolean, green: GLboolean, blue: GLboolean, alpha: GLboolean): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/compileShader) */
    compileShader(shader: WebGLShader): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/copyTexImage2D) */
    copyTexImage2D(target: GLenum, level: GLint, internalformat: GLenum, x: GLint, y: GLint, width: GLsizei, height: GLsizei, border: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/copyTexSubImage2D) */
    copyTexSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, x: GLint, y: GLint, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/createBuffer) */
    createBuffer(): WebGLBuffer;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/createFramebuffer) */
    createFramebuffer(): WebGLFramebuffer;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/createProgram) */
    createProgram(): WebGLProgram;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/createRenderbuffer) */
    createRenderbuffer(): WebGLRenderbuffer;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/createShader) */
    createShader(type: GLenum): WebGLShader | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/createTexture) */
    createTexture(): WebGLTexture;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/cullFace) */
    cullFace(mode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/deleteBuffer) */
    deleteBuffer(buffer: WebGLBuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/deleteFramebuffer) */
    deleteFramebuffer(framebuffer: WebGLFramebuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/deleteProgram) */
    deleteProgram(program: WebGLProgram | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/deleteRenderbuffer) */
    deleteRenderbuffer(renderbuffer: WebGLRenderbuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/deleteShader) */
    deleteShader(shader: WebGLShader | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/deleteTexture) */
    deleteTexture(texture: WebGLTexture | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/depthFunc) */
    depthFunc(func: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/depthMask) */
    depthMask(flag: GLboolean): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/depthRange) */
    depthRange(zNear: GLclampf, zFar: GLclampf): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/detachShader) */
    detachShader(program: WebGLProgram, shader: WebGLShader): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/disable) */
    disable(cap: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/disableVertexAttribArray) */
    disableVertexAttribArray(index: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/drawArrays) */
    drawArrays(mode: GLenum, first: GLint, count: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/drawElements) */
    drawElements(mode: GLenum, count: GLsizei, type: GLenum, offset: GLintptr): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/enable) */
    enable(cap: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/enableVertexAttribArray) */
    enableVertexAttribArray(index: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/finish) */
    finish(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/flush) */
    flush(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/framebufferRenderbuffer) */
    framebufferRenderbuffer(target: GLenum, attachment: GLenum, renderbuffertarget: GLenum, renderbuffer: WebGLRenderbuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/framebufferTexture2D) */
    framebufferTexture2D(target: GLenum, attachment: GLenum, textarget: GLenum, texture: WebGLTexture | null, level: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/frontFace) */
    frontFace(mode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/generateMipmap) */
    generateMipmap(target: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getActiveAttrib) */
    getActiveAttrib(program: WebGLProgram, index: GLuint): WebGLActiveInfo | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getActiveUniform) */
    getActiveUniform(program: WebGLProgram, index: GLuint): WebGLActiveInfo | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getAttachedShaders) */
    getAttachedShaders(program: WebGLProgram): WebGLShader[] | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getAttribLocation) */
    getAttribLocation(program: WebGLProgram, name: string): GLint;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getBufferParameter) */
    getBufferParameter(target: GLenum, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getContextAttributes) */
    getContextAttributes(): WebGLContextAttributes | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getError) */
    getError(): GLenum;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getExtension) */
    getExtension(name: string): any;
    getExtension(extensionName: "ANGLE_instanced_arrays"): ANGLE_instanced_arrays | null;
    getExtension(extensionName: "EXT_blend_minmax"): EXT_blend_minmax | null;
    getExtension(extensionName: "EXT_color_buffer_float"): EXT_color_buffer_float | null;
    getExtension(extensionName: "EXT_color_buffer_half_float"): EXT_color_buffer_half_float | null;
    getExtension(extensionName: "EXT_float_blend"): EXT_float_blend | null;
    getExtension(extensionName: "EXT_frag_depth"): EXT_frag_depth | null;
    getExtension(extensionName: "EXT_sRGB"): EXT_sRGB | null;
    getExtension(extensionName: "EXT_shader_texture_lod"): EXT_shader_texture_lod | null;
    getExtension(extensionName: "EXT_texture_compression_bptc"): EXT_texture_compression_bptc | null;
    getExtension(extensionName: "EXT_texture_compression_rgtc"): EXT_texture_compression_rgtc | null;
    getExtension(extensionName: "EXT_texture_filter_anisotropic"): EXT_texture_filter_anisotropic | null;
    getExtension(extensionName: "KHR_parallel_shader_compile"): KHR_parallel_shader_compile | null;
    getExtension(extensionName: "OES_element_index_uint"): OES_element_index_uint | null;
    getExtension(extensionName: "OES_fbo_render_mipmap"): OES_fbo_render_mipmap | null;
    getExtension(extensionName: "OES_standard_derivatives"): OES_standard_derivatives | null;
    getExtension(extensionName: "OES_texture_float"): OES_texture_float | null;
    getExtension(extensionName: "OES_texture_float_linear"): OES_texture_float_linear | null;
    getExtension(extensionName: "OES_texture_half_float"): OES_texture_half_float | null;
    getExtension(extensionName: "OES_texture_half_float_linear"): OES_texture_half_float_linear | null;
    getExtension(extensionName: "OES_vertex_array_object"): OES_vertex_array_object | null;
    getExtension(extensionName: "OVR_multiview2"): OVR_multiview2 | null;
    getExtension(extensionName: "WEBGL_color_buffer_float"): WEBGL_color_buffer_float | null;
    getExtension(extensionName: "WEBGL_compressed_texture_astc"): WEBGL_compressed_texture_astc | null;
    getExtension(extensionName: "WEBGL_compressed_texture_etc"): WEBGL_compressed_texture_etc | null;
    getExtension(extensionName: "WEBGL_compressed_texture_etc1"): WEBGL_compressed_texture_etc1 | null;
    getExtension(extensionName: "WEBGL_compressed_texture_pvrtc"): WEBGL_compressed_texture_pvrtc | null;
    getExtension(extensionName: "WEBGL_compressed_texture_s3tc"): WEBGL_compressed_texture_s3tc | null;
    getExtension(extensionName: "WEBGL_compressed_texture_s3tc_srgb"): WEBGL_compressed_texture_s3tc_srgb | null;
    getExtension(extensionName: "WEBGL_debug_renderer_info"): WEBGL_debug_renderer_info | null;
    getExtension(extensionName: "WEBGL_debug_shaders"): WEBGL_debug_shaders | null;
    getExtension(extensionName: "WEBGL_depth_texture"): WEBGL_depth_texture | null;
    getExtension(extensionName: "WEBGL_draw_buffers"): WEBGL_draw_buffers | null;
    getExtension(extensionName: "WEBGL_lose_context"): WEBGL_lose_context | null;
    getExtension(extensionName: "WEBGL_multi_draw"): WEBGL_multi_draw | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getFramebufferAttachmentParameter) */
    getFramebufferAttachmentParameter(target: GLenum, attachment: GLenum, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getParameter) */
    getParameter(pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getProgramInfoLog) */
    getProgramInfoLog(program: WebGLProgram): string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getProgramParameter) */
    getProgramParameter(program: WebGLProgram, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getRenderbufferParameter) */
    getRenderbufferParameter(target: GLenum, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getShaderInfoLog) */
    getShaderInfoLog(shader: WebGLShader): string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getShaderParameter) */
    getShaderParameter(shader: WebGLShader, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getShaderPrecisionFormat) */
    getShaderPrecisionFormat(shadertype: GLenum, precisiontype: GLenum): WebGLShaderPrecisionFormat | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getShaderSource) */
    getShaderSource(shader: WebGLShader): string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getSupportedExtensions) */
    getSupportedExtensions(): string[] | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getTexParameter) */
    getTexParameter(target: GLenum, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getUniform) */
    getUniform(program: WebGLProgram, location: WebGLUniformLocation): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getUniformLocation) */
    getUniformLocation(program: WebGLProgram, name: string): WebGLUniformLocation | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getVertexAttrib) */
    getVertexAttrib(index: GLuint, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/getVertexAttribOffset) */
    getVertexAttribOffset(index: GLuint, pname: GLenum): GLintptr;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/hint) */
    hint(target: GLenum, mode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isBuffer) */
    isBuffer(buffer: WebGLBuffer | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isContextLost) */
    isContextLost(): boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isEnabled) */
    isEnabled(cap: GLenum): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isFramebuffer) */
    isFramebuffer(framebuffer: WebGLFramebuffer | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isProgram) */
    isProgram(program: WebGLProgram | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isRenderbuffer) */
    isRenderbuffer(renderbuffer: WebGLRenderbuffer | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isShader) */
    isShader(shader: WebGLShader | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/isTexture) */
    isTexture(texture: WebGLTexture | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/lineWidth) */
    lineWidth(width: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/linkProgram) */
    linkProgram(program: WebGLProgram): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/pixelStorei) */
    pixelStorei(pname: GLenum, param: GLint | GLboolean): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/polygonOffset) */
    polygonOffset(factor: GLfloat, units: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/renderbufferStorage) */
    renderbufferStorage(target: GLenum, internalformat: GLenum, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/sampleCoverage) */
    sampleCoverage(value: GLclampf, invert: GLboolean): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/scissor) */
    scissor(x: GLint, y: GLint, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/shaderSource) */
    shaderSource(shader: WebGLShader, source: string): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/stencilFunc) */
    stencilFunc(func: GLenum, ref: GLint, mask: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/stencilFuncSeparate) */
    stencilFuncSeparate(face: GLenum, func: GLenum, ref: GLint, mask: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/stencilMask) */
    stencilMask(mask: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/stencilMaskSeparate) */
    stencilMaskSeparate(face: GLenum, mask: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/stencilOp) */
    stencilOp(fail: GLenum, zfail: GLenum, zpass: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/stencilOpSeparate) */
    stencilOpSeparate(face: GLenum, fail: GLenum, zfail: GLenum, zpass: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/texParameter) */
    texParameterf(target: GLenum, pname: GLenum, param: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/texParameter) */
    texParameteri(target: GLenum, pname: GLenum, param: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1f(location: WebGLUniformLocation | null, x: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1i(location: WebGLUniformLocation | null, x: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2f(location: WebGLUniformLocation | null, x: GLfloat, y: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2i(location: WebGLUniformLocation | null, x: GLint, y: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3f(location: WebGLUniformLocation | null, x: GLfloat, y: GLfloat, z: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3i(location: WebGLUniformLocation | null, x: GLint, y: GLint, z: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4f(location: WebGLUniformLocation | null, x: GLfloat, y: GLfloat, z: GLfloat, w: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4i(location: WebGLUniformLocation | null, x: GLint, y: GLint, z: GLint, w: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/useProgram) */
    useProgram(program: WebGLProgram | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/validateProgram) */
    validateProgram(program: WebGLProgram): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib1f(index: GLuint, x: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib1fv(index: GLuint, values: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib2f(index: GLuint, x: GLfloat, y: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib2fv(index: GLuint, values: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib3f(index: GLuint, x: GLfloat, y: GLfloat, z: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib3fv(index: GLuint, values: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib4f(index: GLuint, x: GLfloat, y: GLfloat, z: GLfloat, w: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib4fv(index: GLuint, values: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttribPointer) */
    vertexAttribPointer(index: GLuint, size: GLint, type: GLenum, normalized: GLboolean, stride: GLsizei, offset: GLintptr): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/viewport) */
    viewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei): void;
    readonly DEPTH_BUFFER_BIT: 0x00000100;
    readonly STENCIL_BUFFER_BIT: 0x00000400;
    readonly COLOR_BUFFER_BIT: 0x00004000;
    readonly POINTS: 0x0000;
    readonly LINES: 0x0001;
    readonly LINE_LOOP: 0x0002;
    readonly LINE_STRIP: 0x0003;
    readonly TRIANGLES: 0x0004;
    readonly TRIANGLE_STRIP: 0x0005;
    readonly TRIANGLE_FAN: 0x0006;
    readonly ZERO: 0;
    readonly ONE: 1;
    readonly SRC_COLOR: 0x0300;
    readonly ONE_MINUS_SRC_COLOR: 0x0301;
    readonly SRC_ALPHA: 0x0302;
    readonly ONE_MINUS_SRC_ALPHA: 0x0303;
    readonly DST_ALPHA: 0x0304;
    readonly ONE_MINUS_DST_ALPHA: 0x0305;
    readonly DST_COLOR: 0x0306;
    readonly ONE_MINUS_DST_COLOR: 0x0307;
    readonly SRC_ALPHA_SATURATE: 0x0308;
    readonly FUNC_ADD: 0x8006;
    readonly BLEND_EQUATION: 0x8009;
    readonly BLEND_EQUATION_RGB: 0x8009;
    readonly BLEND_EQUATION_ALPHA: 0x883D;
    readonly FUNC_SUBTRACT: 0x800A;
    readonly FUNC_REVERSE_SUBTRACT: 0x800B;
    readonly BLEND_DST_RGB: 0x80C8;
    readonly BLEND_SRC_RGB: 0x80C9;
    readonly BLEND_DST_ALPHA: 0x80CA;
    readonly BLEND_SRC_ALPHA: 0x80CB;
    readonly CONSTANT_COLOR: 0x8001;
    readonly ONE_MINUS_CONSTANT_COLOR: 0x8002;
    readonly CONSTANT_ALPHA: 0x8003;
    readonly ONE_MINUS_CONSTANT_ALPHA: 0x8004;
    readonly BLEND_COLOR: 0x8005;
    readonly ARRAY_BUFFER: 0x8892;
    readonly ELEMENT_ARRAY_BUFFER: 0x8893;
    readonly ARRAY_BUFFER_BINDING: 0x8894;
    readonly ELEMENT_ARRAY_BUFFER_BINDING: 0x8895;
    readonly STREAM_DRAW: 0x88E0;
    readonly STATIC_DRAW: 0x88E4;
    readonly DYNAMIC_DRAW: 0x88E8;
    readonly BUFFER_SIZE: 0x8764;
    readonly BUFFER_USAGE: 0x8765;
    readonly CURRENT_VERTEX_ATTRIB: 0x8626;
    readonly FRONT: 0x0404;
    readonly BACK: 0x0405;
    readonly FRONT_AND_BACK: 0x0408;
    readonly CULL_FACE: 0x0B44;
    readonly BLEND: 0x0BE2;
    readonly DITHER: 0x0BD0;
    readonly STENCIL_TEST: 0x0B90;
    readonly DEPTH_TEST: 0x0B71;
    readonly SCISSOR_TEST: 0x0C11;
    readonly POLYGON_OFFSET_FILL: 0x8037;
    readonly SAMPLE_ALPHA_TO_COVERAGE: 0x809E;
    readonly SAMPLE_COVERAGE: 0x80A0;
    readonly NO_ERROR: 0;
    readonly INVALID_ENUM: 0x0500;
    readonly INVALID_VALUE: 0x0501;
    readonly INVALID_OPERATION: 0x0502;
    readonly OUT_OF_MEMORY: 0x0505;
    readonly CW: 0x0900;
    readonly CCW: 0x0901;
    readonly LINE_WIDTH: 0x0B21;
    readonly ALIASED_POINT_SIZE_RANGE: 0x846D;
    readonly ALIASED_LINE_WIDTH_RANGE: 0x846E;
    readonly CULL_FACE_MODE: 0x0B45;
    readonly FRONT_FACE: 0x0B46;
    readonly DEPTH_RANGE: 0x0B70;
    readonly DEPTH_WRITEMASK: 0x0B72;
    readonly DEPTH_CLEAR_VALUE: 0x0B73;
    readonly DEPTH_FUNC: 0x0B74;
    readonly STENCIL_CLEAR_VALUE: 0x0B91;
    readonly STENCIL_FUNC: 0x0B92;
    readonly STENCIL_FAIL: 0x0B94;
    readonly STENCIL_PASS_DEPTH_FAIL: 0x0B95;
    readonly STENCIL_PASS_DEPTH_PASS: 0x0B96;
    readonly STENCIL_REF: 0x0B97;
    readonly STENCIL_VALUE_MASK: 0x0B93;
    readonly STENCIL_WRITEMASK: 0x0B98;
    readonly STENCIL_BACK_FUNC: 0x8800;
    readonly STENCIL_BACK_FAIL: 0x8801;
    readonly STENCIL_BACK_PASS_DEPTH_FAIL: 0x8802;
    readonly STENCIL_BACK_PASS_DEPTH_PASS: 0x8803;
    readonly STENCIL_BACK_REF: 0x8CA3;
    readonly STENCIL_BACK_VALUE_MASK: 0x8CA4;
    readonly STENCIL_BACK_WRITEMASK: 0x8CA5;
    readonly VIEWPORT: 0x0BA2;
    readonly SCISSOR_BOX: 0x0C10;
    readonly COLOR_CLEAR_VALUE: 0x0C22;
    readonly COLOR_WRITEMASK: 0x0C23;
    readonly UNPACK_ALIGNMENT: 0x0CF5;
    readonly PACK_ALIGNMENT: 0x0D05;
    readonly MAX_TEXTURE_SIZE: 0x0D33;
    readonly MAX_VIEWPORT_DIMS: 0x0D3A;
    readonly SUBPIXEL_BITS: 0x0D50;
    readonly RED_BITS: 0x0D52;
    readonly GREEN_BITS: 0x0D53;
    readonly BLUE_BITS: 0x0D54;
    readonly ALPHA_BITS: 0x0D55;
    readonly DEPTH_BITS: 0x0D56;
    readonly STENCIL_BITS: 0x0D57;
    readonly POLYGON_OFFSET_UNITS: 0x2A00;
    readonly POLYGON_OFFSET_FACTOR: 0x8038;
    readonly TEXTURE_BINDING_2D: 0x8069;
    readonly SAMPLE_BUFFERS: 0x80A8;
    readonly SAMPLES: 0x80A9;
    readonly SAMPLE_COVERAGE_VALUE: 0x80AA;
    readonly SAMPLE_COVERAGE_INVERT: 0x80AB;
    readonly COMPRESSED_TEXTURE_FORMATS: 0x86A3;
    readonly DONT_CARE: 0x1100;
    readonly FASTEST: 0x1101;
    readonly NICEST: 0x1102;
    readonly GENERATE_MIPMAP_HINT: 0x8192;
    readonly BYTE: 0x1400;
    readonly UNSIGNED_BYTE: 0x1401;
    readonly SHORT: 0x1402;
    readonly UNSIGNED_SHORT: 0x1403;
    readonly INT: 0x1404;
    readonly UNSIGNED_INT: 0x1405;
    readonly FLOAT: 0x1406;
    readonly DEPTH_COMPONENT: 0x1902;
    readonly ALPHA: 0x1906;
    readonly RGB: 0x1907;
    readonly RGBA: 0x1908;
    readonly LUMINANCE: 0x1909;
    readonly LUMINANCE_ALPHA: 0x190A;
    readonly UNSIGNED_SHORT_4_4_4_4: 0x8033;
    readonly UNSIGNED_SHORT_5_5_5_1: 0x8034;
    readonly UNSIGNED_SHORT_5_6_5: 0x8363;
    readonly FRAGMENT_SHADER: 0x8B30;
    readonly VERTEX_SHADER: 0x8B31;
    readonly MAX_VERTEX_ATTRIBS: 0x8869;
    readonly MAX_VERTEX_UNIFORM_VECTORS: 0x8DFB;
    readonly MAX_VARYING_VECTORS: 0x8DFC;
    readonly MAX_COMBINED_TEXTURE_IMAGE_UNITS: 0x8B4D;
    readonly MAX_VERTEX_TEXTURE_IMAGE_UNITS: 0x8B4C;
    readonly MAX_TEXTURE_IMAGE_UNITS: 0x8872;
    readonly MAX_FRAGMENT_UNIFORM_VECTORS: 0x8DFD;
    readonly SHADER_TYPE: 0x8B4F;
    readonly DELETE_STATUS: 0x8B80;
    readonly LINK_STATUS: 0x8B82;
    readonly VALIDATE_STATUS: 0x8B83;
    readonly ATTACHED_SHADERS: 0x8B85;
    readonly ACTIVE_UNIFORMS: 0x8B86;
    readonly ACTIVE_ATTRIBUTES: 0x8B89;
    readonly SHADING_LANGUAGE_VERSION: 0x8B8C;
    readonly CURRENT_PROGRAM: 0x8B8D;
    readonly NEVER: 0x0200;
    readonly LESS: 0x0201;
    readonly EQUAL: 0x0202;
    readonly LEQUAL: 0x0203;
    readonly GREATER: 0x0204;
    readonly NOTEQUAL: 0x0205;
    readonly GEQUAL: 0x0206;
    readonly ALWAYS: 0x0207;
    readonly KEEP: 0x1E00;
    readonly REPLACE: 0x1E01;
    readonly INCR: 0x1E02;
    readonly DECR: 0x1E03;
    readonly INVERT: 0x150A;
    readonly INCR_WRAP: 0x8507;
    readonly DECR_WRAP: 0x8508;
    readonly VENDOR: 0x1F00;
    readonly RENDERER: 0x1F01;
    readonly VERSION: 0x1F02;
    readonly NEAREST: 0x2600;
    readonly LINEAR: 0x2601;
    readonly NEAREST_MIPMAP_NEAREST: 0x2700;
    readonly LINEAR_MIPMAP_NEAREST: 0x2701;
    readonly NEAREST_MIPMAP_LINEAR: 0x2702;
    readonly LINEAR_MIPMAP_LINEAR: 0x2703;
    readonly TEXTURE_MAG_FILTER: 0x2800;
    readonly TEXTURE_MIN_FILTER: 0x2801;
    readonly TEXTURE_WRAP_S: 0x2802;
    readonly TEXTURE_WRAP_T: 0x2803;
    readonly TEXTURE_2D: 0x0DE1;
    readonly TEXTURE: 0x1702;
    readonly TEXTURE_CUBE_MAP: 0x8513;
    readonly TEXTURE_BINDING_CUBE_MAP: 0x8514;
    readonly TEXTURE_CUBE_MAP_POSITIVE_X: 0x8515;
    readonly TEXTURE_CUBE_MAP_NEGATIVE_X: 0x8516;
    readonly TEXTURE_CUBE_MAP_POSITIVE_Y: 0x8517;
    readonly TEXTURE_CUBE_MAP_NEGATIVE_Y: 0x8518;
    readonly TEXTURE_CUBE_MAP_POSITIVE_Z: 0x8519;
    readonly TEXTURE_CUBE_MAP_NEGATIVE_Z: 0x851A;
    readonly MAX_CUBE_MAP_TEXTURE_SIZE: 0x851C;
    readonly TEXTURE0: 0x84C0;
    readonly TEXTURE1: 0x84C1;
    readonly TEXTURE2: 0x84C2;
    readonly TEXTURE3: 0x84C3;
    readonly TEXTURE4: 0x84C4;
    readonly TEXTURE5: 0x84C5;
    readonly TEXTURE6: 0x84C6;
    readonly TEXTURE7: 0x84C7;
    readonly TEXTURE8: 0x84C8;
    readonly TEXTURE9: 0x84C9;
    readonly TEXTURE10: 0x84CA;
    readonly TEXTURE11: 0x84CB;
    readonly TEXTURE12: 0x84CC;
    readonly TEXTURE13: 0x84CD;
    readonly TEXTURE14: 0x84CE;
    readonly TEXTURE15: 0x84CF;
    readonly TEXTURE16: 0x84D0;
    readonly TEXTURE17: 0x84D1;
    readonly TEXTURE18: 0x84D2;
    readonly TEXTURE19: 0x84D3;
    readonly TEXTURE20: 0x84D4;
    readonly TEXTURE21: 0x84D5;
    readonly TEXTURE22: 0x84D6;
    readonly TEXTURE23: 0x84D7;
    readonly TEXTURE24: 0x84D8;
    readonly TEXTURE25: 0x84D9;
    readonly TEXTURE26: 0x84DA;
    readonly TEXTURE27: 0x84DB;
    readonly TEXTURE28: 0x84DC;
    readonly TEXTURE29: 0x84DD;
    readonly TEXTURE30: 0x84DE;
    readonly TEXTURE31: 0x84DF;
    readonly ACTIVE_TEXTURE: 0x84E0;
    readonly REPEAT: 0x2901;
    readonly CLAMP_TO_EDGE: 0x812F;
    readonly MIRRORED_REPEAT: 0x8370;
    readonly FLOAT_VEC2: 0x8B50;
    readonly FLOAT_VEC3: 0x8B51;
    readonly FLOAT_VEC4: 0x8B52;
    readonly INT_VEC2: 0x8B53;
    readonly INT_VEC3: 0x8B54;
    readonly INT_VEC4: 0x8B55;
    readonly BOOL: 0x8B56;
    readonly BOOL_VEC2: 0x8B57;
    readonly BOOL_VEC3: 0x8B58;
    readonly BOOL_VEC4: 0x8B59;
    readonly FLOAT_MAT2: 0x8B5A;
    readonly FLOAT_MAT3: 0x8B5B;
    readonly FLOAT_MAT4: 0x8B5C;
    readonly SAMPLER_2D: 0x8B5E;
    readonly SAMPLER_CUBE: 0x8B60;
    readonly VERTEX_ATTRIB_ARRAY_ENABLED: 0x8622;
    readonly VERTEX_ATTRIB_ARRAY_SIZE: 0x8623;
    readonly VERTEX_ATTRIB_ARRAY_STRIDE: 0x8624;
    readonly VERTEX_ATTRIB_ARRAY_TYPE: 0x8625;
    readonly VERTEX_ATTRIB_ARRAY_NORMALIZED: 0x886A;
    readonly VERTEX_ATTRIB_ARRAY_POINTER: 0x8645;
    readonly VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: 0x889F;
    readonly IMPLEMENTATION_COLOR_READ_TYPE: 0x8B9A;
    readonly IMPLEMENTATION_COLOR_READ_FORMAT: 0x8B9B;
    readonly COMPILE_STATUS: 0x8B81;
    readonly LOW_FLOAT: 0x8DF0;
    readonly MEDIUM_FLOAT: 0x8DF1;
    readonly HIGH_FLOAT: 0x8DF2;
    readonly LOW_INT: 0x8DF3;
    readonly MEDIUM_INT: 0x8DF4;
    readonly HIGH_INT: 0x8DF5;
    readonly FRAMEBUFFER: 0x8D40;
    readonly RENDERBUFFER: 0x8D41;
    readonly RGBA4: 0x8056;
    readonly RGB5_A1: 0x8057;
    readonly RGBA8: 0x8058;
    readonly RGB565: 0x8D62;
    readonly DEPTH_COMPONENT16: 0x81A5;
    readonly STENCIL_INDEX8: 0x8D48;
    readonly DEPTH_STENCIL: 0x84F9;
    readonly RENDERBUFFER_WIDTH: 0x8D42;
    readonly RENDERBUFFER_HEIGHT: 0x8D43;
    readonly RENDERBUFFER_INTERNAL_FORMAT: 0x8D44;
    readonly RENDERBUFFER_RED_SIZE: 0x8D50;
    readonly RENDERBUFFER_GREEN_SIZE: 0x8D51;
    readonly RENDERBUFFER_BLUE_SIZE: 0x8D52;
    readonly RENDERBUFFER_ALPHA_SIZE: 0x8D53;
    readonly RENDERBUFFER_DEPTH_SIZE: 0x8D54;
    readonly RENDERBUFFER_STENCIL_SIZE: 0x8D55;
    readonly FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: 0x8CD0;
    readonly FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: 0x8CD1;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: 0x8CD2;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE: 0x8CD3;
    readonly COLOR_ATTACHMENT0: 0x8CE0;
    readonly DEPTH_ATTACHMENT: 0x8D00;
    readonly STENCIL_ATTACHMENT: 0x8D20;
    readonly DEPTH_STENCIL_ATTACHMENT: 0x821A;
    readonly NONE: 0;
    readonly FRAMEBUFFER_COMPLETE: 0x8CD5;
    readonly FRAMEBUFFER_INCOMPLETE_ATTACHMENT: 0x8CD6;
    readonly FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT: 0x8CD7;
    readonly FRAMEBUFFER_INCOMPLETE_DIMENSIONS: 0x8CD9;
    readonly FRAMEBUFFER_UNSUPPORTED: 0x8CDD;
    readonly FRAMEBUFFER_BINDING: 0x8CA6;
    readonly RENDERBUFFER_BINDING: 0x8CA7;
    readonly MAX_RENDERBUFFER_SIZE: 0x84E8;
    readonly INVALID_FRAMEBUFFER_OPERATION: 0x0506;
    readonly UNPACK_FLIP_Y_WEBGL: 0x9240;
    readonly UNPACK_PREMULTIPLY_ALPHA_WEBGL: 0x9241;
    readonly CONTEXT_LOST_WEBGL: 0x9242;
    readonly UNPACK_COLORSPACE_CONVERSION_WEBGL: 0x9243;
    readonly BROWSER_DEFAULT_WEBGL: 0x9244;
}

interface WebGLRenderingContextOverloads {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bufferData) */
    bufferData(target: GLenum, size: GLsizeiptr, usage: GLenum): void;
    bufferData(target: GLenum, data: AllowSharedBufferSource | null, usage: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/bufferSubData) */
    bufferSubData(target: GLenum, offset: GLintptr, data: AllowSharedBufferSource): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/compressedTexImage2D) */
    compressedTexImage2D(target: GLenum, level: GLint, internalformat: GLenum, width: GLsizei, height: GLsizei, border: GLint, data: ArrayBufferView<ArrayBufferLike>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/compressedTexSubImage2D) */
    compressedTexSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, data: ArrayBufferView<ArrayBufferLike>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/readPixels) */
    readPixels(x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pixels: ArrayBufferView<ArrayBufferLike> | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/texImage2D) */
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, pixels: ArrayBufferView<ArrayBufferLike> | null): void;
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, format: GLenum, type: GLenum, source: TexImageSource): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/texSubImage2D) */
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pixels: ArrayBufferView<ArrayBufferLike> | null): void;
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, format: GLenum, type: GLenum, source: TexImageSource): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1fv(location: WebGLUniformLocation | null, v: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1iv(location: WebGLUniformLocation | null, v: Int32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2fv(location: WebGLUniformLocation | null, v: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2iv(location: WebGLUniformLocation | null, v: Int32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3fv(location: WebGLUniformLocation | null, v: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3iv(location: WebGLUniformLocation | null, v: Int32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4fv(location: WebGLUniformLocation | null, v: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4iv(location: WebGLUniformLocation | null, v: Int32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix2fv(location: WebGLUniformLocation | null, transpose: GLboolean, value: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix3fv(location: WebGLUniformLocation | null, transpose: GLboolean, value: Float32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix4fv(location: WebGLUniformLocation | null, transpose: GLboolean, value: Float32List): void;
}

/**
 * The **`WebGLSampler`** interface is part of the WebGL 2 API and stores sampling parameters for WebGLTexture access inside of a shader.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLSampler)
 */
interface WebGLSampler {
}

declare var WebGLSampler: {
    prototype: WebGLSampler;
    new(): WebGLSampler;
};

/**
 * The **`WebGLShader`** is part of the WebGL API and can either be a vertex or a fragment shader. A WebGLProgram requires both types of shaders.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLShader)
 */
interface WebGLShader {
}

declare var WebGLShader: {
    prototype: WebGLShader;
    new(): WebGLShader;
};

/**
 * The **`WebGLShaderPrecisionFormat`** interface is part of the WebGL API and represents the information returned by calling the WebGLRenderingContext.getShaderPrecisionFormat() method.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLShaderPrecisionFormat)
 */
interface WebGLShaderPrecisionFormat {
    /**
     * The read-only **`WebGLShaderPrecisionFormat.precision`** property returns the number of bits of precision that can be represented.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLShaderPrecisionFormat/precision)
     */
    readonly precision: GLint;
    /**
     * The read-only **`WebGLShaderPrecisionFormat.rangeMax`** property returns the base 2 log of the absolute value of the maximum value that can be represented.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLShaderPrecisionFormat/rangeMax)
     */
    readonly rangeMax: GLint;
    /**
     * The read-only **`WebGLShaderPrecisionFormat.rangeMin`** property returns the base 2 log of the absolute value of the minimum value that can be represented.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLShaderPrecisionFormat/rangeMin)
     */
    readonly rangeMin: GLint;
}

declare var WebGLShaderPrecisionFormat: {
    prototype: WebGLShaderPrecisionFormat;
    new(): WebGLShaderPrecisionFormat;
};

/**
 * The **`WebGLSync`** interface is part of the WebGL 2 API and is used to synchronize activities between the GPU and the application.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLSync)
 */
interface WebGLSync {
}

declare var WebGLSync: {
    prototype: WebGLSync;
    new(): WebGLSync;
};

/**
 * The **`WebGLTexture`** interface is part of the WebGL API and represents an opaque texture object providing storage and state for texturing operations.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLTexture)
 */
interface WebGLTexture {
}

declare var WebGLTexture: {
    prototype: WebGLTexture;
    new(): WebGLTexture;
};

/**
 * The **`WebGLTransformFeedback`** interface is part of the WebGL 2 API and enables transform feedback, which is the process of capturing primitives generated by vertex processing. It allows to preserve the post-transform rendering state of an object and resubmit this data multiple times.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLTransformFeedback)
 */
interface WebGLTransformFeedback {
}

declare var WebGLTransformFeedback: {
    prototype: WebGLTransformFeedback;
    new(): WebGLTransformFeedback;
};

/**
 * The **`WebGLUniformLocation`** interface is part of the WebGL API and represents the location of a uniform variable in a shader program.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLUniformLocation)
 */
interface WebGLUniformLocation {
}

declare var WebGLUniformLocation: {
    prototype: WebGLUniformLocation;
    new(): WebGLUniformLocation;
};

/**
 * The **`WebGLVertexArrayObject`** interface is part of the WebGL 2 API, represents vertex array objects (VAOs) pointing to vertex array data, and provides names for different sets of vertex data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLVertexArrayObject)
 */
interface WebGLVertexArrayObject {
}

declare var WebGLVertexArrayObject: {
    prototype: WebGLVertexArrayObject;
    new(): WebGLVertexArrayObject;
};

/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLVertexArrayObject) */
interface WebGLVertexArrayObjectOES {
}

interface WebSocketEventMap {
    "close": CloseEvent;
    "error": Event;
    "message": MessageEvent;
    "open": Event;
}

/**
 * The **`WebSocket`** object provides the API for creating and managing a WebSocket connection to a server, as well as for sending and receiving data on the connection.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket)
 */
interface WebSocket extends EventTarget {
    /**
     * The **`WebSocket.binaryType`** property controls the type of binary data being received over the WebSocket connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/binaryType)
     */
    binaryType: BinaryType;
    /**
     * The **`WebSocket.bufferedAmount`** read-only property returns the number of bytes of data that have been queued using calls to send() but not yet transmitted to the network. This value resets to zero once all queued data has been sent. This value does not reset to zero when the connection is closed; if you keep calling send(), this will continue to climb.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/bufferedAmount)
     */
    readonly bufferedAmount: number;
    /**
     * The **`WebSocket.extensions`** read-only property returns the extensions selected by the server. This is currently only the empty string or a list of extensions as negotiated by the connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/extensions)
     */
    readonly extensions: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/close_event) */
    onclose: ((this: WebSocket, ev: CloseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/error_event) */
    onerror: ((this: WebSocket, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/message_event) */
    onmessage: ((this: WebSocket, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/open_event) */
    onopen: ((this: WebSocket, ev: Event) => any) | null;
    /**
     * The **`WebSocket.protocol`** read-only property returns the name of the sub-protocol the server selected; this will be one of the strings specified in the protocols parameter when creating the WebSocket object, or the empty string if no connection is established.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/protocol)
     */
    readonly protocol: string;
    /**
     * The **`WebSocket.readyState`** read-only property returns the current state of the WebSocket connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/readyState)
     */
    readonly readyState: 0 | 1 | 2 | 3;
    /**
     * The **`WebSocket.url`** read-only property returns the absolute URL of the WebSocket as resolved by the constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/url)
     */
    readonly url: string;
    /**
     * The **`WebSocket.close()`** method closes the WebSocket connection or connection attempt, if any. If the connection is already CLOSED, this method does nothing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/close)
     */
    close(code?: number, reason?: string): void;
    /**
     * The **`WebSocket.send()`** method enqueues the specified data to be transmitted to the server over the WebSocket connection, increasing the value of bufferedAmount by the number of bytes needed to contain the data. If the data can't be sent (for example, because it needs to be buffered but the buffer is full), the socket is closed automatically. The browser will throw an exception if you call send() when the connection is in the CONNECTING state. If you call send() when the connection is in the CLOSING or CLOSED states, the browser will silently discard the data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebSocket/send)
     */
    send(data: BufferSource | Blob | string): void;
    readonly CONNECTING: 0;
    readonly OPEN: 1;
    readonly CLOSING: 2;
    readonly CLOSED: 3;
    addEventListener<K extends keyof WebSocketEventMap>(type: K, listener: (this: WebSocket, ev: WebSocketEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof WebSocketEventMap>(type: K, listener: (this: WebSocket, ev: WebSocketEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var WebSocket: {
    prototype: WebSocket;
    new(url: string | URL, protocols?: string | string[]): WebSocket;
    readonly CONNECTING: 0;
    readonly OPEN: 1;
    readonly CLOSING: 2;
    readonly CLOSED: 3;
};

/**
 * The **`WebTransport`** interface of the WebTransport API provides functionality to enable a user agent to connect to an HTTP/3 server, initiate reliable and unreliable transport in either or both directions, and close the connection once it is no longer needed.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport)
 */
interface WebTransport {
    /**
     * The **`closed`** read-only property of the WebTransport interface returns a promise that resolves when the transport is closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/closed)
     */
    readonly closed: Promise<WebTransportCloseInfo>;
    /**
     * The **`datagrams`** read-only property of the WebTransport interface returns a WebTransportDatagramDuplexStream instance that can be used to send and receive datagrams — unreliable data transmission.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/datagrams)
     */
    readonly datagrams: WebTransportDatagramDuplexStream;
    /**
     * The **`incomingBidirectionalStreams`** read-only property of the WebTransport interface represents one or more bidirectional streams opened by the server. Returns a ReadableStream of WebTransportBidirectionalStream objects. Each one can be used to reliably read data from the server and write data back to it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/incomingBidirectionalStreams)
     */
    readonly incomingBidirectionalStreams: ReadableStream;
    /**
     * The **`incomingUnidirectionalStreams`** read-only property of the WebTransport interface represents one or more unidirectional streams opened by the server. Returns a ReadableStream of WebTransportReceiveStream objects. Each one can be used to reliably read data from the server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/incomingUnidirectionalStreams)
     */
    readonly incomingUnidirectionalStreams: ReadableStream;
    /**
     * The **`ready`** read-only property of the WebTransport interface returns a promise that resolves when the transport is ready to use.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/ready)
     */
    readonly ready: Promise<void>;
    /**
     * The **`close()`** method of the WebTransport interface closes an ongoing WebTransport session.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/close)
     */
    close(closeInfo?: WebTransportCloseInfo): void;
    /**
     * The **`createBidirectionalStream()`** method of the WebTransport interface asynchronously opens and returns a bidirectional stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/createBidirectionalStream)
     */
    createBidirectionalStream(options?: WebTransportSendStreamOptions): Promise<WebTransportBidirectionalStream>;
    /**
     * The **`createUnidirectionalStream()`** method of the WebTransport interface asynchronously opens a unidirectional stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransport/createUnidirectionalStream)
     */
    createUnidirectionalStream(options?: WebTransportSendStreamOptions): Promise<WritableStream>;
}

declare var WebTransport: {
    prototype: WebTransport;
    new(url: string | URL, options?: WebTransportOptions): WebTransport;
};

/**
 * The **`WebTransportBidirectionalStream`** interface of the WebTransport API represents a bidirectional stream created by a server or a client that can be used for reliable transport. Provides access to a WebTransportReceiveStream for reading incoming data, and a WebTransportSendStream for writing outgoing data.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportBidirectionalStream)
 */
interface WebTransportBidirectionalStream {
    /**
     * The **`readable`** read-only property of the WebTransportBidirectionalStream interface returns a WebTransportReceiveStream instance that can be used to reliably read incoming data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportBidirectionalStream/readable)
     */
    readonly readable: ReadableStream;
    /**
     * The **`writable`** read-only property of the WebTransportBidirectionalStream interface returns a WebTransportSendStream instance that can be used to write outgoing data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportBidirectionalStream/writable)
     */
    readonly writable: WritableStream;
}

declare var WebTransportBidirectionalStream: {
    prototype: WebTransportBidirectionalStream;
    new(): WebTransportBidirectionalStream;
};

/**
 * The **`WebTransportDatagramDuplexStream`** interface of the WebTransport API represents a duplex stream that can be used for unreliable transport of datagrams between client and server. Provides access to a ReadableStream for reading incoming datagrams, a WritableStream for writing outgoing datagrams, and various settings and statistics related to the stream.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream)
 */
interface WebTransportDatagramDuplexStream {
    /**
     * The **`incomingHighWaterMark`** property of the WebTransportDatagramDuplexStream interface gets or sets the high water mark for incoming chunks of data — this is the maximum size, in chunks, that the incoming ReadableStream's internal queue can reach before it is considered full. See Internal queues and queuing strategies for more information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/incomingHighWaterMark)
     */
    incomingHighWaterMark: number;
    /**
     * The **`incomingMaxAge`** property of the WebTransportDatagramDuplexStream interface gets or sets the maximum age for incoming datagrams, in milliseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/incomingMaxAge)
     */
    incomingMaxAge: number | null;
    /**
     * The **`maxDatagramSize`** read-only property of the WebTransportDatagramDuplexStream interface returns the maximum allowable size of outgoing datagrams, in bytes, that can be written to writable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/maxDatagramSize)
     */
    readonly maxDatagramSize: number;
    /**
     * The **`outgoingHighWaterMark`** property of the WebTransportDatagramDuplexStream interface gets or sets the high water mark for outgoing chunks of data — this is the maximum size, in chunks, that the outgoing WritableStream's internal queue can reach before it is considered full. See Internal queues and queuing strategies for more information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/outgoingHighWaterMark)
     */
    outgoingHighWaterMark: number;
    /**
     * The **`outgoingMaxAge`** property of the WebTransportDatagramDuplexStream interface gets or sets the maximum age for outgoing datagrams, in milliseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/outgoingMaxAge)
     */
    outgoingMaxAge: number | null;
    /**
     * The **`readable`** read-only property of the WebTransportDatagramDuplexStream interface returns a ReadableStream instance that can be used to unreliably read incoming datagrams from the stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/readable)
     */
    readonly readable: ReadableStream;
    /**
     * The **`writable`** read-only property of the WebTransportDatagramDuplexStream interface returns a WritableStream instance that can be used to unreliably write outgoing datagrams to the stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportDatagramDuplexStream/writable)
     */
    readonly writable: WritableStream;
}

declare var WebTransportDatagramDuplexStream: {
    prototype: WebTransportDatagramDuplexStream;
    new(): WebTransportDatagramDuplexStream;
};

/**
 * The **`WebTransportError`** interface of the WebTransport API represents an error related to the API, which can arise from server errors, network connection problems, or client-initiated abort operations (for example, arising from a WritableStream.abort() call).
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportError)
 */
interface WebTransportError extends DOMException {
    /**
     * The **`source`** read-only property of the WebTransportError interface returns an enumerated value indicating the source of the error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportError/source)
     */
    readonly source: WebTransportErrorSource;
    /**
     * The **`streamErrorCode`** read-only property of the WebTransportError interface returns a number in the range 0-255 indicating the application protocol error code for this error, or null if one is not available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebTransportError/streamErrorCode)
     */
    readonly streamErrorCode: number | null;
}

declare var WebTransportError: {
    prototype: WebTransportError;
    new(message?: string, options?: WebTransportErrorOptions): WebTransportError;
};

/**
 * The **`WheelEvent`** interface represents events that occur due to the user moving a mouse wheel or similar input device.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WheelEvent)
 */
interface WheelEvent extends MouseEvent {
    /**
     * The **`WheelEvent.deltaMode`** read-only property returns an unsigned long representing the unit of the delta values scroll amount. Permitted values are:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WheelEvent/deltaMode)
     */
    readonly deltaMode: number;
    /**
     * The **`WheelEvent.deltaX`** read-only property is a double representing the horizontal scroll amount in the WheelEvent.deltaMode unit.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WheelEvent/deltaX)
     */
    readonly deltaX: number;
    /**
     * The **`WheelEvent.deltaY`** read-only property is a double representing the vertical scroll amount in the WheelEvent.deltaMode unit.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WheelEvent/deltaY)
     */
    readonly deltaY: number;
    /**
     * The **`WheelEvent.deltaZ`** read-only property is a double representing the scroll amount along the z-axis, in the WheelEvent.deltaMode unit.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WheelEvent/deltaZ)
     */
    readonly deltaZ: number;
    readonly DOM_DELTA_PIXEL: 0x00;
    readonly DOM_DELTA_LINE: 0x01;
    readonly DOM_DELTA_PAGE: 0x02;
}

declare var WheelEvent: {
    prototype: WheelEvent;
    new(type: string, eventInitDict?: WheelEventInit): WheelEvent;
    readonly DOM_DELTA_PIXEL: 0x00;
    readonly DOM_DELTA_LINE: 0x01;
    readonly DOM_DELTA_PAGE: 0x02;
};

interface WindowEventMap extends GlobalEventHandlersEventMap, WindowEventHandlersEventMap {
    "DOMContentLoaded": Event;
    "devicemotion": DeviceMotionEvent;
    "deviceorientation": DeviceOrientationEvent;
    "deviceorientationabsolute": DeviceOrientationEvent;
    "gamepadconnected": GamepadEvent;
    "gamepaddisconnected": GamepadEvent;
    "orientationchange": Event;
}

/**
 * The **`Window`** interface represents a window containing a DOM document; the document property points to the DOM document loaded in that window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window)
 */
interface Window extends EventTarget, AnimationFrameProvider, GlobalEventHandlers, WindowEventHandlers, WindowLocalStorage, WindowOrWorkerGlobalScope, WindowSessionStorage {
    /**
     * @deprecated This is a legacy alias of `navigator`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/navigator)
     */
    readonly clientInformation: Navigator;
    /**
     * The **`Window.closed`** read-only property indicates whether the referenced window is closed or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/closed)
     */
    readonly closed: boolean;
    /**
     * The **`cookieStore`** read-only property of the Window interface returns a reference to the CookieStore object for the current document context. This is an entry point for the Cookie Store API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/cookieStore)
     */
    readonly cookieStore: CookieStore;
    /**
     * The **`customElements`** read-only property of the Window interface returns a reference to the CustomElementRegistry object, which can be used to register new custom elements and get information about previously registered custom elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/customElements)
     */
    readonly customElements: CustomElementRegistry;
    /**
     * The **`devicePixelRatio`** of Window interface returns the ratio of the resolution in physical pixels to the resolution in CSS pixels for the current display device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/devicePixelRatio)
     */
    readonly devicePixelRatio: number;
    /**
     * **`window.document`** returns a reference to the document contained in the window.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/document)
     */
    readonly document: Document;
    /**
     * The read-only Window property **`event`** returns the Event which is currently being handled by the site's code. Outside the context of an event handler, the value is always undefined.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/event)
     */
    readonly event: Event | undefined;
    /**
     * The **`external`** property of the Window API returns an instance of the External interface, which was intended to contain functions related to adding external search providers to the browser. However, this is now deprecated, and the contained methods are now dummy functions that do nothing as per spec.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/external)
     */
    readonly external: External;
    /**
     * The **`Window.frameElement`** property returns the element (such as <iframe> or <object>) in which the window is embedded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/frameElement)
     */
    readonly frameElement: Element | null;
    /**
     * Returns the window itself, which is an array-like object, listing the direct sub-**`frames`** of the current window.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/frames)
     */
    readonly frames: WindowProxy;
    /**
     * The **`Window.history`** read-only property returns a reference to the History object, which provides an interface for manipulating the browser session history (pages visited in the tab or frame that the current page is loaded in).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/history)
     */
    readonly history: History;
    /**
     * The read-only **`innerHeight`** property of the Window interface returns the interior height of the window in pixels, including the height of the horizontal scroll bar, if present.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/innerHeight)
     */
    readonly innerHeight: number;
    /**
     * The read-only Window property **`innerWidth`** returns the interior width of the window in pixels (that is, the width of the window's layout viewport). That includes the width of the vertical scroll bar, if one is present.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/innerWidth)
     */
    readonly innerWidth: number;
    /**
     * Returns the number of frames (either <frame> or <iframe> elements) in the window.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/length)
     */
    readonly length: number;
    /**
     * The read-only **`location`** property of the Window interface returns a Location object with information about the current location of the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/location)
     */
    get location(): Location;
    set location(href: string);
    /**
     * Returns the **`locationbar`** object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/locationbar)
     */
    readonly locationbar: BarProp;
    /**
     * Returns the **`menubar`** object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/menubar)
     */
    readonly menubar: BarProp;
    /**
     * The **`Window.name`** property gets/sets the name of the window's browsing context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/name)
     */
    name: string;
    /**
     * The **`navigation`** read-only property of the Window interface returns the current window's associated Navigation object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/navigation)
     */
    readonly navigation: Navigation;
    /**
     * The **`Window.navigator`** read-only property returns a reference to the Navigator object, which has methods and properties about the application running the script.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/navigator)
     */
    readonly navigator: Navigator;
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/devicemotion_event)
     */
    ondevicemotion: ((this: Window, ev: DeviceMotionEvent) => any) | null;
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/deviceorientation_event)
     */
    ondeviceorientation: ((this: Window, ev: DeviceOrientationEvent) => any) | null;
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/deviceorientationabsolute_event)
     */
    ondeviceorientationabsolute: ((this: Window, ev: DeviceOrientationEvent) => any) | null;
    /**
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/orientationchange_event)
     */
    onorientationchange: ((this: Window, ev: Event) => any) | null;
    /**
     * The Window interface's **`opener`** property returns a reference to the window that opened the window, either with open(), or by navigating a link with a target attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/opener)
     */
    opener: any;
    /**
     * Returns the **`orientation`** in degrees (in 90-degree increments) of the viewport relative to the device's natural orientation.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/orientation)
     */
    readonly orientation: number;
    /**
     * The **`originAgentCluster`** read-only property of the Window interface returns true if this window belongs to an origin-keyed agent cluster: this means that the operating system has provided dedicated resources (for example an operating system process) to this window's origin that are not shared with windows from other origins.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/originAgentCluster)
     */
    readonly originAgentCluster: boolean;
    /**
     * The **`Window.outerHeight`** read-only property returns the height in pixels of the whole browser window, including any sidebar, window chrome, and window-resizing borders/handles.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/outerHeight)
     */
    readonly outerHeight: number;
    /**
     * **`Window.outerWidth`** read-only property returns the width of the outside of the browser window. It represents the width of the whole browser window including sidebar (if expanded), window chrome and window resizing borders/handles.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/outerWidth)
     */
    readonly outerWidth: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollX) */
    readonly pageXOffset: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollY) */
    readonly pageYOffset: number;
    /**
     * The **`Window.parent`** property is a reference to the parent of the current window or subframe.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/parent)
     */
    readonly parent: WindowProxy;
    /**
     * Returns the **`personalbar`** object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/personalbar)
     */
    readonly personalbar: BarProp;
    /**
     * The Window property **`screen`** returns a reference to the screen object associated with the window. The screen object, implementing the Screen interface, is a special object for inspecting properties of the screen on which the current window is being rendered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screen)
     */
    readonly screen: Screen;
    /**
     * The **`Window.screenLeft`** read-only property returns the horizontal distance, in CSS pixels, from the left border of the user's browser viewport to the left side of the screen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenLeft)
     */
    readonly screenLeft: number;
    /**
     * The **`Window.screenTop`** read-only property returns the vertical distance, in CSS pixels, from the top border of the user's browser viewport to the top side of the screen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenTop)
     */
    readonly screenTop: number;
    /**
     * The **`Window.screenX`** read-only property returns the horizontal distance, in CSS pixels, of the left border of the user's browser viewport to the left side of the screen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenX)
     */
    readonly screenX: number;
    /**
     * The **`Window.screenY`** read-only property returns the vertical distance, in CSS pixels, of the top border of the user's browser viewport to the top edge of the screen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenY)
     */
    readonly screenY: number;
    /**
     * The read-only **`scrollX`** property of the Window interface returns the number of pixels by which the document is currently scrolled horizontally. This value is subpixel precise in modern browsers, meaning that it isn't necessarily a whole number. You can get the number of pixels the document is scrolled vertically from the scrollY property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollX)
     */
    readonly scrollX: number;
    /**
     * The read-only **`scrollY`** property of the Window interface returns the number of pixels by which the document is currently scrolled vertically. This value is subpixel precise in modern browsers, meaning that it isn't necessarily a whole number. You can get the number of pixels the document is scrolled horizontally from the scrollX property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollY)
     */
    readonly scrollY: number;
    /**
     * Returns the **`scrollbars`** object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollbars)
     */
    readonly scrollbars: BarProp;
    /**
     * The **`Window.self`** read-only property returns the window itself, as a WindowProxy. It can be used with dot notation on a window object (that is, window.self) or standalone (self). The advantage of the standalone notation is that a similar notation exists for non-window contexts, such as in Web Workers. By using self, you can refer to the global scope in a way that will work not only in a window context (self will resolve to window.self) but also in a worker context (self will then resolve to WorkerGlobalScope.self).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/self)
     */
    readonly self: Window & typeof globalThis;
    /**
     * The **`speechSynthesis`** read-only property of the Window object returns a SpeechSynthesis object, which is the entry point into using Web Speech API speech synthesis functionality.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/speechSynthesis)
     */
    readonly speechSynthesis: SpeechSynthesis;
    /**
     * The **`status`** property of the Window interface was originally intended to set the text in the status bar at the bottom of the browser window. However, the HTML standard now requires setting window.status to have no effect on the text displayed in the status bar.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/status)
     */
    status: string;
    /**
     * Returns the **`statusbar`** object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/statusbar)
     */
    readonly statusbar: BarProp;
    /**
     * Returns the **`toolbar`** object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/toolbar)
     */
    readonly toolbar: BarProp;
    /**
     * Returns a reference to the **`top`**most window in the window hierarchy.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/top)
     */
    readonly top: WindowProxy | null;
    /**
     * The **`visualViewport`** read-only property of the Window interface returns a VisualViewport object representing the visual viewport for a given window, or null if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/visualViewport)
     */
    readonly visualViewport: VisualViewport | null;
    /**
     * The **`window`** property of a Window object points to the window object itself.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/window)
     */
    readonly window: Window & typeof globalThis;
    /**
     * **`window.alert()`** instructs the browser to display a dialog with an optional message, and to wait until the user dismisses the dialog.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/alert)
     */
    alert(message?: any): void;
    /**
     * The **`Window.blur()`** method does nothing.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/blur)
     */
    blur(): void;
    /**
     * The **`window.cancelIdleCallback()`** method cancels a callback previously scheduled with window.requestIdleCallback().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/cancelIdleCallback)
     */
    cancelIdleCallback(handle: number): void;
    /**
     * The **`Window.captureEvents()`** method does nothing. Its original behavior has been removed from the specification, but the method itself has been retained so as not to break code that calls it.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/captureEvents)
     */
    captureEvents(): void;
    /**
     * The **`Window.close()`** method closes the current window, or the window on which it was called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/close)
     */
    close(): void;
    /**
     * **`window.confirm()`** instructs the browser to display a dialog with an optional message, and to wait until the user either confirms or cancels the dialog.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/confirm)
     */
    confirm(message?: string): boolean;
    /**
     * Makes a request to bring the window to the front. It may fail due to user settings and the window isn't guaranteed to be frontmost before this method returns.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/focus)
     */
    focus(): void;
    /**
     * The **`Window.getComputedStyle()`** method returns a live read-only CSSStyleProperties object containing the resolved values of all CSS properties of an element, after applying active stylesheets and resolving any computation those values may contain.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/getComputedStyle)
     */
    getComputedStyle(elt: Element, pseudoElt?: string | null): CSSStyleDeclaration;
    /**
     * The **`getSelection()`** method of the Window interface returns the Selection object associated with the window's document, representing the range of text selected by the user or the current position of the caret.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/getSelection)
     */
    getSelection(): Selection | null;
    /**
     * The Window interface's **`matchMedia()`** method returns a new MediaQueryList object that can then be used to determine if the document matches the media query string, as well as to monitor the document to detect when it matches (or stops matching) that media query.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/matchMedia)
     */
    matchMedia(query: string): MediaQueryList;
    /**
     * The **`moveBy()`** method of the Window interface moves the current window by a specified amount.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/moveBy)
     */
    moveBy(x: number, y: number): void;
    /**
     * The **`moveTo()`** method of the Window interface moves the current window to the specified coordinates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/moveTo)
     */
    moveTo(x: number, y: number): void;
    /**
     * The **`open()`** method of the Window interface loads a specified resource into a new or existing browsing context (that is, a tab, a window, or an iframe) under a specified name.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/open)
     */
    open(url?: string | URL, target?: string, features?: string): WindowProxy | null;
    /**
     * The **`window.postMessage()`** method safely enables cross-origin communication between Window objects; e.g., between a page and a pop-up that it spawned, or between a page and an iframe embedded within it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/postMessage)
     */
    postMessage(message: any, targetOrigin: string, transfer?: Transferable[]): void;
    postMessage(message: any, options?: WindowPostMessageOptions): void;
    /**
     * Opens the **`print`** dialog to print the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/print)
     */
    print(): void;
    /**
     * **`window.prompt()`** instructs the browser to display a dialog with an optional message prompting the user to input some text, and to wait until the user either submits the text or cancels the dialog.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/prompt)
     */
    prompt(message?: string, _default?: string): string | null;
    /**
     * Releases the window from trapping events of a specific type.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/releaseEvents)
     */
    releaseEvents(): void;
    /**
     * The **`window.requestIdleCallback()`** method queues a function to be called during a browser's idle periods. This enables developers to perform background and low priority work on the main thread, without impacting latency-critical events such as animation and input response. Functions are generally called in first-in-first-out order; however, callbacks which have a timeout specified may be called out-of-order if necessary in order to run them before the timeout elapses.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/requestIdleCallback)
     */
    requestIdleCallback(callback: IdleRequestCallback, options?: IdleRequestOptions): number;
    /**
     * The **`Window.resizeBy()`** method resizes the current window by a specified amount.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/resizeBy)
     */
    resizeBy(x: number, y: number): void;
    /**
     * The **`Window.resizeTo()`** method dynamically resizes the window.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/resizeTo)
     */
    resizeTo(width: number, height: number): void;
    /**
     * The **`Window.scroll()`** method scrolls the window to a particular place in the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scroll)
     */
    scroll(options?: ScrollToOptions): void;
    scroll(x: number, y: number): void;
    /**
     * The **`Window.scrollBy()`** method scrolls the document in the window by the given amount.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollBy)
     */
    scrollBy(options?: ScrollToOptions): void;
    scrollBy(x: number, y: number): void;
    /**
     * **`Window.scrollTo()`** scrolls to a particular set of coordinates in the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollTo)
     */
    scrollTo(options?: ScrollToOptions): void;
    scrollTo(x: number, y: number): void;
    /**
     * The **`window.stop()`** stops further resource loading in the current browsing context, equivalent to the stop button in the browser.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/stop)
     */
    stop(): void;
    addEventListener<K extends keyof WindowEventMap>(type: K, listener: (this: Window, ev: WindowEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof WindowEventMap>(type: K, listener: (this: Window, ev: WindowEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
    [index: number]: Window;
}

declare var Window: {
    prototype: Window;
    new(): Window;
};

interface WindowEventHandlersEventMap {
    "afterprint": Event;
    "beforeprint": Event;
    "beforeunload": BeforeUnloadEvent;
    "gamepadconnected": GamepadEvent;
    "gamepaddisconnected": GamepadEvent;
    "hashchange": HashChangeEvent;
    "languagechange": Event;
    "message": MessageEvent;
    "messageerror": MessageEvent;
    "offline": Event;
    "online": Event;
    "pagehide": PageTransitionEvent;
    "pagereveal": PageRevealEvent;
    "pageshow": PageTransitionEvent;
    "pageswap": PageSwapEvent;
    "popstate": PopStateEvent;
    "rejectionhandled": PromiseRejectionEvent;
    "storage": StorageEvent;
    "unhandledrejection": PromiseRejectionEvent;
    "unload": Event;
}

interface WindowEventHandlers {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/afterprint_event) */
    onafterprint: ((this: WindowEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/beforeprint_event) */
    onbeforeprint: ((this: WindowEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/beforeunload_event) */
    onbeforeunload: ((this: WindowEventHandlers, ev: BeforeUnloadEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/gamepadconnected_event) */
    ongamepadconnected: ((this: WindowEventHandlers, ev: GamepadEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/gamepaddisconnected_event) */
    ongamepaddisconnected: ((this: WindowEventHandlers, ev: GamepadEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/hashchange_event) */
    onhashchange: ((this: WindowEventHandlers, ev: HashChangeEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/languagechange_event) */
    onlanguagechange: ((this: WindowEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/message_event) */
    onmessage: ((this: WindowEventHandlers, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/messageerror_event) */
    onmessageerror: ((this: WindowEventHandlers, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/offline_event) */
    onoffline: ((this: WindowEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/online_event) */
    ononline: ((this: WindowEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pagehide_event) */
    onpagehide: ((this: WindowEventHandlers, ev: PageTransitionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pagereveal_event) */
    onpagereveal: ((this: WindowEventHandlers, ev: PageRevealEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pageshow_event) */
    onpageshow: ((this: WindowEventHandlers, ev: PageTransitionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pageswap_event) */
    onpageswap: ((this: WindowEventHandlers, ev: PageSwapEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/popstate_event) */
    onpopstate: ((this: WindowEventHandlers, ev: PopStateEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/rejectionhandled_event) */
    onrejectionhandled: ((this: WindowEventHandlers, ev: PromiseRejectionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/storage_event) */
    onstorage: ((this: WindowEventHandlers, ev: StorageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/unhandledrejection_event) */
    onunhandledrejection: ((this: WindowEventHandlers, ev: PromiseRejectionEvent) => any) | null;
    /**
     * @deprecated The unload event is not reliable, consider visibilitychange or pagehide events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/unload_event)
     */
    onunload: ((this: WindowEventHandlers, ev: Event) => any) | null;
    addEventListener<K extends keyof WindowEventHandlersEventMap>(type: K, listener: (this: WindowEventHandlers, ev: WindowEventHandlersEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof WindowEventHandlersEventMap>(type: K, listener: (this: WindowEventHandlers, ev: WindowEventHandlersEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

interface WindowLocalStorage {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/localStorage) */
    readonly localStorage: Storage;
}

interface WindowOrWorkerGlobalScope {
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/caches)
     */
    readonly caches: CacheStorage;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/crossOriginIsolated) */
    readonly crossOriginIsolated: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/crypto) */
    readonly crypto: Crypto;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/indexedDB) */
    readonly indexedDB: IDBFactory;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/isSecureContext) */
    readonly isSecureContext: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/origin) */
    readonly origin: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/performance) */
    readonly performance: Performance;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scheduler) */
    readonly scheduler: Scheduler;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/atob) */
    atob(data: string): string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/btoa) */
    btoa(data: string): string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/clearInterval) */
    clearInterval(id: number | undefined): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/clearTimeout) */
    clearTimeout(id: number | undefined): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/createImageBitmap) */
    createImageBitmap(image: ImageBitmapSource, options?: ImageBitmapOptions): Promise<ImageBitmap>;
    createImageBitmap(image: ImageBitmapSource, sx: number, sy: number, sw: number, sh: number, options?: ImageBitmapOptions): Promise<ImageBitmap>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/fetch) */
    fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/queueMicrotask) */
    queueMicrotask(callback: VoidFunction): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/reportError) */
    reportError(e: any): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/setInterval) */
    setInterval(handler: TimerHandler, timeout?: number, ...arguments: any[]): number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/setTimeout) */
    setTimeout(handler: TimerHandler, timeout?: number, ...arguments: any[]): number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/structuredClone) */
    structuredClone<T = any>(value: T, options?: StructuredSerializeOptions): T;
}

interface WindowSessionStorage {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/sessionStorage) */
    readonly sessionStorage: Storage;
}

interface WorkerEventMap extends AbstractWorkerEventMap, MessageEventTargetEventMap {
}

/**
 * The **`Worker`** interface of the Web Workers API represents a background task that can be created via script, which can send messages back to its creator.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Worker)
 */
interface Worker extends EventTarget, AbstractWorker, MessageEventTarget<Worker> {
    /**
     * The **`postMessage()`** method of the Worker interface sends a message to the worker. The first parameter is the data to send to the worker. The data may be any JavaScript object that can be handled by the structured clone algorithm.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Worker/postMessage)
     */
    postMessage(message: any, transfer: Transferable[]): void;
    postMessage(message: any, options?: StructuredSerializeOptions): void;
    /**
     * The **`terminate()`** method of the Worker interface immediately terminates the Worker. This does not offer the worker an opportunity to finish its operations; it is stopped at once.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Worker/terminate)
     */
    terminate(): void;
    addEventListener<K extends keyof WorkerEventMap>(type: K, listener: (this: Worker, ev: WorkerEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof WorkerEventMap>(type: K, listener: (this: Worker, ev: WorkerEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Worker: {
    prototype: Worker;
    new(scriptURL: string | URL, options?: WorkerOptions): Worker;
};

/**
 * The **`Worklet`** interface is a lightweight version of Web Workers and gives developers access to low-level parts of the rendering pipeline.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Worklet)
 */
interface Worklet {
    /**
     * The **`addModule()`** method of the Worklet interface loads the module in the given JavaScript file and adds it to the current Worklet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Worklet/addModule)
     */
    addModule(moduleURL: string | URL, options?: WorkletOptions): Promise<void>;
}

declare var Worklet: {
    prototype: Worklet;
    new(): Worklet;
};

/**
 * The **`WritableStream`** interface of the Streams API provides a standard abstraction for writing streaming data to a destination, known as a sink. This object comes with built-in backpressure and queuing.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStream)
 */
interface WritableStream<W = any> {
    /**
     * The **`locked`** read-only property of the WritableStream interface returns a boolean indicating whether the WritableStream is locked to a writer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStream/locked)
     */
    readonly locked: boolean;
    /**
     * The **`abort()`** method of the WritableStream interface aborts the stream, signaling that the producer can no longer successfully write to the stream and it is to be immediately moved to an error state, with any queued writes discarded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStream/abort)
     */
    abort(reason?: any): Promise<void>;
    /**
     * The **`close()`** method of the WritableStream interface closes the associated stream. All chunks written before this method is called are sent before the returned promise is fulfilled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStream/close)
     */
    close(): Promise<void>;
    /**
     * The **`getWriter()`** method of the WritableStream interface returns a new instance of WritableStreamDefaultWriter and locks the stream to that instance. While the stream is locked, no other writer can be acquired until this one is released.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStream/getWriter)
     */
    getWriter(): WritableStreamDefaultWriter<W>;
}

declare var WritableStream: {
    prototype: WritableStream;
    new<W = any>(underlyingSink?: UnderlyingSink<W>, strategy?: QueuingStrategy<W>): WritableStream<W>;
};

/**
 * The **`WritableStreamDefaultController`** interface of the Streams API represents a controller allowing control of a WritableStream's state. When constructing a WritableStream, the underlying sink is given a corresponding WritableStreamDefaultController instance to manipulate.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultController)
 */
interface WritableStreamDefaultController {
    /**
     * The read-only **`signal`** property of the WritableStreamDefaultController interface returns the AbortSignal associated with the controller.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultController/signal)
     */
    readonly signal: AbortSignal;
    /**
     * The **`error()`** method of the WritableStreamDefaultController interface causes any future interactions with the associated stream to error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultController/error)
     */
    error(e?: any): void;
}

declare var WritableStreamDefaultController: {
    prototype: WritableStreamDefaultController;
    new(): WritableStreamDefaultController;
};

/**
 * The **`WritableStreamDefaultWriter`** interface of the Streams API is the object returned by WritableStream.getWriter() and once created locks the writer to the WritableStream ensuring that no other streams can write to the underlying sink.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter)
 */
interface WritableStreamDefaultWriter<W = any> {
    /**
     * The **`closed`** read-only property of the WritableStreamDefaultWriter interface returns a Promise that fulfills if the stream becomes closed, or rejects if the stream errors or the writer's lock is released.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/closed)
     */
    readonly closed: Promise<void>;
    /**
     * The **`desiredSize`** read-only property of the WritableStreamDefaultWriter interface returns the desired size required to fill the stream's internal queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/desiredSize)
     */
    readonly desiredSize: number | null;
    /**
     * The **`ready`** read-only property of the WritableStreamDefaultWriter interface returns a Promise that resolves when the desired size of the stream's internal queue transitions from non-positive to positive, signaling that it is no longer applying backpressure.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/ready)
     */
    readonly ready: Promise<void>;
    /**
     * The **`abort()`** method of the WritableStreamDefaultWriter interface aborts the stream, signaling that the producer can no longer successfully write to the stream and it is to be immediately moved to an error state, with any queued writes discarded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/abort)
     */
    abort(reason?: any): Promise<void>;
    /**
     * The **`close()`** method of the WritableStreamDefaultWriter interface closes the associated writable stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/close)
     */
    close(): Promise<void>;
    /**
     * The **`releaseLock()`** method of the WritableStreamDefaultWriter interface releases the writer's lock on the corresponding stream. After the lock is released, the writer is no longer active. If the associated stream is errored when the lock is released, the writer will appear errored in the same way from now on; otherwise, the writer will appear closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/releaseLock)
     */
    releaseLock(): void;
    /**
     * The **`write()`** method of the WritableStreamDefaultWriter interface writes a passed chunk of data to a WritableStream and its underlying sink, then returns a Promise that resolves to indicate the success or failure of the write operation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WritableStreamDefaultWriter/write)
     */
    write(chunk?: W): Promise<void>;
}

declare var WritableStreamDefaultWriter: {
    prototype: WritableStreamDefaultWriter;
    new<W = any>(stream: WritableStream<W>): WritableStreamDefaultWriter<W>;
};

/**
 * The **`XMLDocument`** interface represents an XML document. It inherits from the generic Document and does not add any specific methods or properties to it: nevertheless, several algorithms behave differently with the two types of documents.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLDocument)
 */
interface XMLDocument extends Document {
    addEventListener<K extends keyof DocumentEventMap>(type: K, listener: (this: XMLDocument, ev: DocumentEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof DocumentEventMap>(type: K, listener: (this: XMLDocument, ev: DocumentEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var XMLDocument: {
    prototype: XMLDocument;
    new(): XMLDocument;
};

interface XMLHttpRequestEventMap extends XMLHttpRequestEventTargetEventMap {
    "readystatechange": Event;
}

/**
 * **`XMLHttpRequest`** (XHR) objects are used to interact with servers. You can retrieve data from a URL without having to do a full page refresh. This enables a Web page to update just part of a page without disrupting what the user is doing.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest)
 */
interface XMLHttpRequest extends XMLHttpRequestEventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/readystatechange_event) */
    onreadystatechange: ((this: XMLHttpRequest, ev: Event) => any) | null;
    /**
     * The **`XMLHttpRequest.readyState`** property returns the state an XMLHttpRequest client is in. An XHR client exists in one of the following states:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/readyState)
     */
    readonly readyState: number;
    /**
     * The XMLHttpRequest **`response`** property returns the response's body content as an ArrayBuffer, a Blob, a Document, a JavaScript Object, or a string, depending on the value of the request's responseType property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/response)
     */
    readonly response: any;
    /**
     * The read-only XMLHttpRequest property **`responseText`** returns the text received from a server following a request being sent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/responseText)
     */
    readonly responseText: string;
    /**
     * The XMLHttpRequest property **`responseType`** is an enumerated string value specifying the type of data contained in the response.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/responseType)
     */
    responseType: XMLHttpRequestResponseType;
    /**
     * The read-only **`XMLHttpRequest.responseURL`** property returns the serialized URL of the response or the empty string if the URL is null. If the URL is returned, any URL fragment present in the URL will be stripped away. The value of responseURL will be the final URL obtained after any redirects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/responseURL)
     */
    readonly responseURL: string;
    /**
     * The **`XMLHttpRequest.responseXML`** read-only property returns a Document containing the HTML or XML retrieved by the request; or null if the request was unsuccessful, has not yet been sent, or if the data can't be parsed as XML or HTML.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/responseXML)
     */
    readonly responseXML: Document | null;
    /**
     * The read-only **`XMLHttpRequest.status`** property returns the numerical HTTP status code of the XMLHttpRequest's response.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/status)
     */
    readonly status: number;
    /**
     * The read-only **`XMLHttpRequest.statusText`** property returns a string containing the response's status message as returned by the HTTP server. Unlike XMLHttpRequest.status which indicates a numerical status code, this property contains the text of the response status, such as "OK" or "Not Found". If the request's readyState is in UNSENT or OPENED state, the value of statusText will be an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/statusText)
     */
    readonly statusText: string;
    /**
     * The **`XMLHttpRequest.timeout`** property is an unsigned long representing the number of milliseconds a request can take before automatically being terminated. The default value is 0, which means there is no timeout. Timeout shouldn't be used for synchronous XMLHttpRequests requests used in a document environment or it will throw an InvalidAccessError exception. When a timeout happens, a timeout event is fired.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/timeout)
     */
    timeout: number;
    /**
     * The XMLHttpRequest **`upload`** property returns an XMLHttpRequestUpload object that can be observed to monitor an upload's progress.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/upload)
     */
    readonly upload: XMLHttpRequestUpload;
    /**
     * The **`XMLHttpRequest.withCredentials`** property is a boolean value that indicates whether or not cross-site Access-Control requests should be made using credentials such as cookies, authentication headers or TLS client certificates. Setting withCredentials has no effect on same-origin requests.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/withCredentials)
     */
    withCredentials: boolean;
    /**
     * The **`XMLHttpRequest.abort()`** method aborts the request if it has already been sent. When a request is aborted, its readyState is changed to XMLHttpRequest.UNSENT (0) and the request's status code is set to 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/abort)
     */
    abort(): void;
    /**
     * The XMLHttpRequest method **`getAllResponseHeaders()`** returns all the response headers, separated by CRLF, as a string, or returns null if no response has been received.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/getAllResponseHeaders)
     */
    getAllResponseHeaders(): string;
    /**
     * The XMLHttpRequest method **`getResponseHeader()`** returns the string containing the text of a particular header's value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/getResponseHeader)
     */
    getResponseHeader(name: string): string | null;
    /**
     * The XMLHttpRequest method **`open()`** initializes a newly-created request, or re-initializes an existing one.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/open)
     */
    open(method: string, url: string | URL): void;
    open(method: string, url: string | URL, async: boolean, username?: string | null, password?: string | null): void;
    /**
     * The XMLHttpRequest method **`overrideMimeType()`** specifies a MIME type other than the one provided by the server to be used instead when interpreting the data being transferred in a request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/overrideMimeType)
     */
    overrideMimeType(mime: string): void;
    /**
     * The XMLHttpRequest method **`send()`** sends the request to the server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/send)
     */
    send(body?: Document | XMLHttpRequestBodyInit | null): void;
    /**
     * The XMLHttpRequest method **`setRequestHeader()`** sets the value of an HTTP request header. When using setRequestHeader(), you must call it after calling open(), but before calling send(). If this method is called several times with the same header, the values are merged into one single request header.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequest/setRequestHeader)
     */
    setRequestHeader(name: string, value: string): void;
    readonly UNSENT: 0;
    readonly OPENED: 1;
    readonly HEADERS_RECEIVED: 2;
    readonly LOADING: 3;
    readonly DONE: 4;
    addEventListener<K extends keyof XMLHttpRequestEventMap>(type: K, listener: (this: XMLHttpRequest, ev: XMLHttpRequestEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof XMLHttpRequestEventMap>(type: K, listener: (this: XMLHttpRequest, ev: XMLHttpRequestEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var XMLHttpRequest: {
    prototype: XMLHttpRequest;
    new(): XMLHttpRequest;
    readonly UNSENT: 0;
    readonly OPENED: 1;
    readonly HEADERS_RECEIVED: 2;
    readonly LOADING: 3;
    readonly DONE: 4;
};

interface XMLHttpRequestEventTargetEventMap {
    "abort": ProgressEvent<XMLHttpRequestEventTarget>;
    "error": ProgressEvent<XMLHttpRequestEventTarget>;
    "load": ProgressEvent<XMLHttpRequestEventTarget>;
    "loadend": ProgressEvent<XMLHttpRequestEventTarget>;
    "loadstart": ProgressEvent<XMLHttpRequestEventTarget>;
    "progress": ProgressEvent<XMLHttpRequestEventTarget>;
    "timeout": ProgressEvent<XMLHttpRequestEventTarget>;
}

/**
 * **`XMLHttpRequestEventTarget`** is the interface that describes the event handlers shared on XMLHttpRequest and XMLHttpRequestUpload.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequestEventTarget)
 */
interface XMLHttpRequestEventTarget extends EventTarget {
    onabort: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    onerror: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    onload: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    onloadend: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    onloadstart: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    onprogress: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    ontimeout: ((this: XMLHttpRequest, ev: ProgressEvent) => any) | null;
    addEventListener<K extends keyof XMLHttpRequestEventTargetEventMap>(type: K, listener: (this: XMLHttpRequestEventTarget, ev: XMLHttpRequestEventTargetEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof XMLHttpRequestEventTargetEventMap>(type: K, listener: (this: XMLHttpRequestEventTarget, ev: XMLHttpRequestEventTargetEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var XMLHttpRequestEventTarget: {
    prototype: XMLHttpRequestEventTarget;
    new(): XMLHttpRequestEventTarget;
};

/**
 * The **`XMLHttpRequestUpload`** interface represents the upload process for a specific XMLHttpRequest. It is an opaque object that represents the underlying, browser-dependent, upload process. It is an XMLHttpRequestEventTarget and can be obtained by calling XMLHttpRequest.upload.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLHttpRequestUpload)
 */
interface XMLHttpRequestUpload extends XMLHttpRequestEventTarget {
    addEventListener<K extends keyof XMLHttpRequestEventTargetEventMap>(type: K, listener: (this: XMLHttpRequestUpload, ev: XMLHttpRequestEventTargetEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof XMLHttpRequestEventTargetEventMap>(type: K, listener: (this: XMLHttpRequestUpload, ev: XMLHttpRequestEventTargetEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var XMLHttpRequestUpload: {
    prototype: XMLHttpRequestUpload;
    new(): XMLHttpRequestUpload;
};

/**
 * The **`XMLSerializer`** interface provides the serializeToString() method to construct an XML string representing a DOM tree.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLSerializer)
 */
interface XMLSerializer {
    /**
     * The XMLSerializer method **`serializeToString()`** constructs a string representing the specified DOM tree in XML form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XMLSerializer/serializeToString)
     */
    serializeToString(root: Node): string;
}

declare var XMLSerializer: {
    prototype: XMLSerializer;
    new(): XMLSerializer;
};

/**
 * The **`XPathEvaluator`** interface allows to compile and evaluate XPath expressions.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathEvaluator)
 */
interface XPathEvaluator extends XPathEvaluatorBase {
}

declare var XPathEvaluator: {
    prototype: XPathEvaluator;
    new(): XPathEvaluator;
};

interface XPathEvaluatorBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createExpression) */
    createExpression(expression: string, resolver?: XPathNSResolver | null): XPathExpression;
    /**
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createNSResolver)
     */
    createNSResolver(nodeResolver: Node): Node;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/evaluate) */
    evaluate(expression: string, contextNode: Node, resolver?: XPathNSResolver | null, type?: number, result?: XPathResult | null): XPathResult;
}

/**
 * This interface is a compiled XPath expression that can be evaluated on a document or specific node to return information from its DOM tree.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathExpression)
 */
interface XPathExpression {
    /**
     * The **`evaluate()`** method of the XPathExpression interface executes an XPath expression on the given node or document and returns an XPathResult.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathExpression/evaluate)
     */
    evaluate(contextNode: Node, type?: number, result?: XPathResult | null): XPathResult;
}

declare var XPathExpression: {
    prototype: XPathExpression;
    new(): XPathExpression;
};

/**
 * The **`XPathResult`** interface represents the results generated by evaluating an XPath expression within the context of a given node.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult)
 */
interface XPathResult {
    /**
     * The read-only **`booleanValue`** property of the XPathResult interface returns the boolean value of a result with XPathResult.resultType being BOOLEAN_TYPE.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/booleanValue)
     */
    readonly booleanValue: boolean;
    /**
     * The read-only **`invalidIteratorState`** property of the XPathResult interface signifies that the iterator has become invalid. It is true if XPathResult.resultType is UNORDERED_NODE_ITERATOR_TYPE or ORDERED_NODE_ITERATOR_TYPE and the document has been modified since this result was returned.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/invalidIteratorState)
     */
    readonly invalidIteratorState: boolean;
    /**
     * The read-only **`numberValue`** property of the XPathResult interface returns the numeric value of a result with XPathResult.resultType being NUMBER_TYPE.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/numberValue)
     */
    readonly numberValue: number;
    /**
     * The read-only **`resultType`** property of the XPathResult interface represents the type of the result, as defined by the type constants.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/resultType)
     */
    readonly resultType: number;
    /**
     * The read-only **`singleNodeValue`** property of the XPathResult interface returns a Node value or null in case no node was matched of a result with XPathResult.resultType being ANY_UNORDERED_NODE_TYPE or FIRST_ORDERED_NODE_TYPE.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/singleNodeValue)
     */
    readonly singleNodeValue: Node | null;
    /**
     * The read-only **`snapshotLength`** property of the XPathResult interface represents the number of nodes in the result snapshot.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/snapshotLength)
     */
    readonly snapshotLength: number;
    /**
     * The read-only **`stringValue`** property of the XPathResult interface returns the string value of a result with XPathResult.resultType being STRING_TYPE.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/stringValue)
     */
    readonly stringValue: string;
    /**
     * The **`iterateNext()`** method of the XPathResult interface iterates over a node set result and returns the next node from it or null if there are no more nodes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/iterateNext)
     */
    iterateNext(): Node | null;
    /**
     * The **`snapshotItem()`** method of the XPathResult interface returns an item of the snapshot collection or null in case the index is not within the range of nodes. Unlike the iterator result, the snapshot does not become invalid, but may not correspond to the current document if it is mutated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XPathResult/snapshotItem)
     */
    snapshotItem(index: number): Node | null;
    readonly ANY_TYPE: 0;
    readonly NUMBER_TYPE: 1;
    readonly STRING_TYPE: 2;
    readonly BOOLEAN_TYPE: 3;
    readonly UNORDERED_NODE_ITERATOR_TYPE: 4;
    readonly ORDERED_NODE_ITERATOR_TYPE: 5;
    readonly UNORDERED_NODE_SNAPSHOT_TYPE: 6;
    readonly ORDERED_NODE_SNAPSHOT_TYPE: 7;
    readonly ANY_UNORDERED_NODE_TYPE: 8;
    readonly FIRST_ORDERED_NODE_TYPE: 9;
}

declare var XPathResult: {
    prototype: XPathResult;
    new(): XPathResult;
    readonly ANY_TYPE: 0;
    readonly NUMBER_TYPE: 1;
    readonly STRING_TYPE: 2;
    readonly BOOLEAN_TYPE: 3;
    readonly UNORDERED_NODE_ITERATOR_TYPE: 4;
    readonly ORDERED_NODE_ITERATOR_TYPE: 5;
    readonly UNORDERED_NODE_SNAPSHOT_TYPE: 6;
    readonly ORDERED_NODE_SNAPSHOT_TYPE: 7;
    readonly ANY_UNORDERED_NODE_TYPE: 8;
    readonly FIRST_ORDERED_NODE_TYPE: 9;
};

/**
 * An **`XSLTProcessor`** applies an XSLT stylesheet transformation to an XML document to produce a new XML document as output. It has methods to load the XSLT stylesheet, to manipulate <xsl:param> parameter values, and to apply the transformation to documents.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor)
 */
interface XSLTProcessor {
    /**
     * The **`clearParameters()`** method of the XSLTProcessor interface removes all parameters (<xsl:param>) and their values from the stylesheet imported in the processor. The XSLTProcessor will then use the default values specified in the XSLT stylesheet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/clearParameters)
     */
    clearParameters(): void;
    /**
     * The **`getParameter()`** method of the XSLTProcessor interface returns the value of a parameter (<xsl:param>) from the stylesheet imported in the processor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/getParameter)
     */
    getParameter(namespaceURI: string | null, localName: string): any;
    /**
     * The **`importStylesheet()`** method of the XSLTProcessor interface imports an XSLT stylesheet for the processor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/importStylesheet)
     */
    importStylesheet(style: Node): void;
    /**
     * The **`removeParameter()`** method of the XSLTProcessor interface removes the parameter (<xsl:param>) and its value from the stylesheet imported in the processor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/removeParameter)
     */
    removeParameter(namespaceURI: string | null, localName: string): void;
    /**
     * The **`reset()`** method of the XSLTProcessor interface removes all parameters (<xsl:param>) and the XSLT stylesheet from the processor. The XSLTProcessor will then be in its original state when it was created.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/reset)
     */
    reset(): void;
    /**
     * The **`setParameter()`** method of the XSLTProcessor interface sets the value of a parameter (<xsl:param>) in the stylesheet imported in the processor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/setParameter)
     */
    setParameter(namespaceURI: string | null, localName: string, value: any): void;
    /**
     * The **`transformToDocument()`** method of the XSLTProcessor interface transforms the provided Node source to a Document using the XSLT stylesheet associated with XSLTProcessor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/transformToDocument)
     */
    transformToDocument(source: Node): Document;
    /**
     * The **`transformToFragment()`** method of the XSLTProcessor interface transforms a provided Node source to a DocumentFragment using the XSLT stylesheet associated with the XSLTProcessor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/XSLTProcessor/transformToFragment)
     */
    transformToFragment(source: Node, output: Document): DocumentFragment;
}

declare var XSLTProcessor: {
    prototype: XSLTProcessor;
    new(): XSLTProcessor;
};

/** The **`CSS`** interface holds useful CSS-related methods. No objects with this interface are implemented: it contains only static methods and is therefore a utilitarian interface. */
declare namespace CSS {
    /**
     * The static, read-only **`highlights`** property of the CSS interface provides access to the HighlightRegistry used to style arbitrary text ranges using the CSS Custom Highlight API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/highlights_static)
     */
    var highlights: HighlightRegistry;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function Hz(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function Q(value: number): CSSUnitValue;
    function cap(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function ch(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cm(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cqb(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cqh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cqi(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cqmax(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cqmin(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function cqw(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function deg(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dpcm(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dpi(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dppx(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dvb(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dvh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dvi(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dvmax(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dvmin(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function dvw(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function em(value: number): CSSUnitValue;
    /**
     * The **`CSS.escape()`** static method returns a string containing the escaped string passed as parameter, mostly for use as part of a CSS selector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/escape_static)
     */
    function escape(ident: string): string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function ex(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function fr(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function grad(value: number): CSSUnitValue;
    function ic(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function kHz(value: number): CSSUnitValue;
    function lh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function lvb(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function lvh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function lvi(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function lvmax(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function lvmin(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function lvw(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function mm(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function ms(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function number(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function pc(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function percent(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function pt(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function px(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function rad(value: number): CSSUnitValue;
    function rcap(value: number): CSSUnitValue;
    function rch(value: number): CSSUnitValue;
    /**
     * The **`CSS.registerProperty()`** static method registers custom properties, allowing for property type checking, default values, and properties that do or do not inherit their value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/registerProperty_static)
     */
    function registerProperty(definition: PropertyDefinition): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function rem(value: number): CSSUnitValue;
    function rex(value: number): CSSUnitValue;
    function ric(value: number): CSSUnitValue;
    function rlh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function s(value: number): CSSUnitValue;
    /**
     * The **`CSS.supports()`** static method returns a boolean value indicating if the browser supports a given CSS feature, or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/supports_static)
     */
    function supports(property: string, value: string): boolean;
    function supports(conditionText: string): boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function svb(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function svh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function svi(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function svmax(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function svmin(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function svw(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function turn(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function vb(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function vh(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function vi(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function vmax(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function vmin(value: number): CSSUnitValue;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CSS/factory_functions_static) */
    function vw(value: number): CSSUnitValue;
}

declare namespace WebAssembly {
    /** The **`WebAssembly.CompileError`** object indicates an error during WebAssembly decoding or validation. */
    interface CompileError extends Error {
    }

    var CompileError: {
        prototype: CompileError;
        new(message?: string): CompileError;
        (message?: string): CompileError;
    };

    /**
     * The **`WebAssembly.Exception`** object represents a runtime exception thrown from WebAssembly to JavaScript, or thrown from JavaScript to a WebAssembly exception handler.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Exception)
     */
    interface Exception {
        /**
         * The read-only **`stack`** property of an object instance of type WebAssembly.Exception may contain a stack trace.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Exception/stack)
         */
        readonly stack: string | undefined;
        /**
         * The **`getArg()`** prototype method of the Exception object can be used to get the value of a specified item in the exception's data arguments.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Exception/getArg)
         */
        getArg(exceptionTag: Tag, index: number): any;
        /**
         * The **`is()`** prototype method of the Exception object can be used to test if the Exception matches a given tag.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Exception/is)
         */
        is(exceptionTag: Tag): boolean;
    }

    var Exception: {
        prototype: Exception;
        new(exceptionTag: Tag, payload: any[], options?: ExceptionOptions): Exception;
    };

    /**
     * A **`WebAssembly.Global`** object represents a global variable instance, accessible from both JavaScript and importable/exportable across one or more WebAssembly.Module instances. This allows dynamic linking of multiple modules.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Global)
     */
    interface Global<T extends ValueType = ValueType> {
        value: ValueTypeMap[T];
        valueOf(): ValueTypeMap[T];
    }

    var Global: {
        prototype: Global;
        new<T extends ValueType = ValueType>(descriptor: GlobalDescriptor<T>, v?: ValueTypeMap[T]): Global<T>;
    };

    /**
     * A **`WebAssembly.Instance`** object is a stateful, executable instance of a WebAssembly.Module. Instance objects contain all the Exported WebAssembly functions that allow calling into WebAssembly code from JavaScript.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Instance)
     */
    interface Instance {
        /**
         * The **`exports`** read-only property of the WebAssembly.Instance object prototype returns an object containing as its members all the functions exported from the WebAssembly module instance, to allow them to be accessed and used by JavaScript.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Instance/exports)
         */
        readonly exports: Exports;
    }

    var Instance: {
        prototype: Instance;
        new(module: Module, importObject?: Imports): Instance;
    };

    /** The **`WebAssembly.LinkError`** object indicates an error during module instantiation (besides traps from the start function). */
    interface LinkError extends Error {
    }

    var LinkError: {
        prototype: LinkError;
        new(message?: string): LinkError;
        (message?: string): LinkError;
    };

    /**
     * The **`WebAssembly.Memory`** object is a resizable ArrayBuffer or SharedArrayBuffer that holds raw bytes of memory accessed by a WebAssembly.Instance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Memory)
     */
    interface Memory {
        /**
         * The read-only **`buffer`** prototype property of the WebAssembly.Memory object returns the buffer contained in the memory. Depending on whether or not the memory was constructed with shared: true, the buffer is either an ArrayBuffer or a SharedArrayBuffer.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Memory/buffer)
         */
        readonly buffer: ArrayBuffer;
        /**
         * The **`grow()`** prototype method of the WebAssembly.Memory object increases the size of the memory instance by a specified number of WebAssembly pages.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Memory/grow)
         */
        grow(delta: AddressValue): AddressValue;
        toFixedLengthBuffer(): ArrayBuffer;
        toResizableBuffer(): ArrayBuffer;
    }

    var Memory: {
        prototype: Memory;
        new(descriptor: MemoryDescriptor): Memory;
    };

    /**
     * A **`WebAssembly.Module`** object contains stateless WebAssembly code that has already been compiled by the browser — this can be efficiently shared with Workers, and instantiated multiple times.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Module)
     */
    interface Module {
    }

    var Module: {
        prototype: Module;
        new(bytes: BufferSource, options?: WebAssemblyCompileOptions): Module;
        /**
         * The WebAssembly.**`Module.customSections()`** static method returns a copy of the contents of all custom sections in the given module with the given string name.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Module/customSections_static)
         */
        customSections(moduleObject: Module, sectionName: string): ArrayBuffer[];
        /**
         * The WebAssembly.**`Module.exports()`** static method returns an array containing descriptions of all the declared exports of the given Module.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Module/exports_static)
         */
        exports(moduleObject: Module): ModuleExportDescriptor[];
        /**
         * The WebAssembly.**`Module.imports()`** static method returns an array containing descriptions of all the declared imports of the given Module.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Module/imports_static)
         */
        imports(moduleObject: Module): ModuleImportDescriptor[];
    };

    /** The **`WebAssembly.RuntimeError`** object is the error type that is thrown whenever WebAssembly specifies a trap. */
    interface RuntimeError extends Error {
    }

    var RuntimeError: {
        prototype: RuntimeError;
        new(message?: string): RuntimeError;
        (message?: string): RuntimeError;
    };

    /**
     * The **`WebAssembly.Table`** object is a JavaScript wrapper object — an array-like structure representing a WebAssembly table, which stores homogeneous references. A table created by JavaScript or in WebAssembly code will be accessible and mutable from both JavaScript and WebAssembly.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table)
     */
    interface Table {
        /**
         * The read-only **`length`** prototype property of the WebAssembly.Table object returns the length of the table, i.e., the number of elements in the table.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/length)
         */
        readonly length: AddressValue;
        /**
         * The **`get()`** prototype method of the WebAssembly.Table() object retrieves the element stored at a given index.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/get)
         */
        get(index: AddressValue): any;
        /**
         * The **`grow()`** prototype method of the WebAssembly.Table object increases the size of the Table instance by a specified number of elements, filled with the provided value.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/grow)
         */
        grow(delta: AddressValue, value?: any): AddressValue;
        /**
         * The **`set()`** prototype method of the WebAssembly.Table object mutates a reference stored at a given index to a different value.
         *
         * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Table/set)
         */
        set(index: AddressValue, value?: any): void;
    }

    var Table: {
        prototype: Table;
        new(descriptor: TableDescriptor, value?: any): Table;
    };

    /**
     * The **`WebAssembly.Tag`** object defines a type of a WebAssembly exception that can be thrown to/from WebAssembly code.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/Tag)
     */
    interface Tag {
    }

    var Tag: {
        prototype: Tag;
        new(type: TagType): Tag;
    };

    interface ExceptionOptions {
        traceStack?: boolean;
    }

    interface GlobalDescriptor<T extends ValueType = ValueType> {
        mutable?: boolean;
        value: T;
    }

    interface MemoryDescriptor {
        address?: AddressType;
        initial: AddressValue;
        maximum?: AddressValue;
        shared?: boolean;
    }

    interface ModuleExportDescriptor {
        kind: ImportExportKind;
        name: string;
    }

    interface ModuleImportDescriptor {
        kind: ImportExportKind;
        module: string;
        name: string;
    }

    interface TableDescriptor {
        address?: AddressType;
        element: TableKind;
        initial: AddressValue;
        maximum?: AddressValue;
    }

    interface TagType {
        parameters: ValueType[];
    }

    interface ValueTypeMap {
        anyfunc: Function;
        externref: any;
        f32: number;
        f64: number;
        i32: number;
        i64: bigint;
        v128: never;
    }

    interface WebAssemblyCompileOptions {
        builtins?: string[];
        importedStringConstants?: string | null;
    }

    interface WebAssemblyInstantiatedSource {
        instance: Instance;
        module: Module;
    }

    type AddressType = "i32" | "i64";
    type ImportExportKind = "function" | "global" | "memory" | "table" | "tag";
    type TableKind = "anyfunc" | "externref";
    type AddressValue = number;
    type ExportValue = Function | Global | Memory | Table;
    type Exports = Record<string, ExportValue>;
    type ImportValue = ExportValue | number;
    type Imports = Record<string, ModuleImports>;
    type ModuleImports = Record<string, ImportValue>;
    type ValueType = keyof ValueTypeMap;
    var JSTag: Tag;
    /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/compile_static) */
    function compile(bytes: BufferSource, options?: WebAssemblyCompileOptions): Promise<Module>;
    /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/compileStreaming_static) */
    function compileStreaming(source: Response | PromiseLike<Response>, options?: WebAssemblyCompileOptions): Promise<Module>;
    /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/instantiate_static) */
    function instantiate(bytes: BufferSource, importObject?: Imports, options?: WebAssemblyCompileOptions): Promise<WebAssemblyInstantiatedSource>;
    function instantiate(moduleObject: Module, importObject?: Imports): Promise<Instance>;
    /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/instantiateStreaming_static) */
    function instantiateStreaming(source: Response | PromiseLike<Response>, importObject?: Imports, options?: WebAssemblyCompileOptions): Promise<WebAssemblyInstantiatedSource>;
    /** [MDN Reference](https://developer.mozilla.org/docs/WebAssembly/Reference/JavaScript_interface/validate_static) */
    function validate(bytes: BufferSource, options?: WebAssemblyCompileOptions): boolean;
}

/** The **`console`** object provides access to the debugging console (e.g., the Web console in Firefox). */
/**
 * The **`console`** object provides access to the debugging console (e.g., the Web console in Firefox).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console)
 */
interface Console {
    /**
     * The **`console.assert()`** static method writes an error message to the console if the assertion is false. If the assertion is true, nothing happens.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/assert_static)
     */
    assert(condition?: boolean, ...data: any[]): void;
    /**
     * The **`console.clear()`** static method clears the console if possible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/clear_static)
     */
    clear(): void;
    /**
     * The **`console.count()`** static method logs the number of times that this particular call to count() has been called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/count_static)
     */
    count(label?: string): void;
    /**
     * The **`console.countReset()`** static method resets counter used with console.count().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/countReset_static)
     */
    countReset(label?: string): void;
    /**
     * The **`console.debug()`** static method outputs a message to the console at the "debug" log level. The message is only displayed to the user if the console is configured to display debug output. In most cases, the log level is configured within the console UI. This log level might correspond to the Debug or Verbose log level.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/debug_static)
     */
    debug(...data: any[]): void;
    /**
     * The **`console.dir()`** static method displays a list of the properties of the specified JavaScript object. In browser consoles, the output is presented as a hierarchical listing with disclosure triangles that let you see the contents of child objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/dir_static)
     */
    dir(item?: any, options?: any): void;
    /**
     * The **`console.dirxml()`** static method displays an interactive tree of the descendant elements of the specified XML/HTML element. If it is not possible to display as an element the JavaScript Object view is shown instead. The output is presented as a hierarchical listing of expandable nodes that let you see the contents of child nodes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/dirxml_static)
     */
    dirxml(...data: any[]): void;
    /**
     * The **`console.error()`** static method outputs a message to the console at the "error" log level. The message is only displayed to the user if the console is configured to display error output. In most cases, the log level is configured within the console UI. The message may be formatted as an error, with red colors and call stack information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/error_static)
     */
    error(...data: any[]): void;
    /**
     * The **`console.group()`** static method creates a new inline group in the Web console log, causing any subsequent console messages to be indented by an additional level, until console.groupEnd() is called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/group_static)
     */
    group(...data: any[]): void;
    /**
     * The **`console.groupCollapsed()`** static method creates a new inline group in the console. Unlike console.group(), however, the new group is created collapsed. The user will need to use the disclosure button next to it to expand it, revealing the entries created in the group.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/groupCollapsed_static)
     */
    groupCollapsed(...data: any[]): void;
    /**
     * The **`console.groupEnd()`** static method exits the current inline group in the console. See Using groups in the console in the console documentation for details and examples.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/groupEnd_static)
     */
    groupEnd(): void;
    /**
     * The **`console.info()`** static method outputs a message to the console at the "info" log level. The message is only displayed to the user if the console is configured to display info output. In most cases, the log level is configured within the console UI. The message may receive special formatting, such as a small "i" icon next to it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/info_static)
     */
    info(...data: any[]): void;
    /**
     * The **`console.log()`** static method outputs a message to the console.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/log_static)
     */
    log(...data: any[]): void;
    /**
     * The **`console.table()`** static method displays tabular data as a table.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/table_static)
     */
    table(tabularData?: any, properties?: string[]): void;
    /**
     * The **`console.time()`** static method starts a timer you can use to track how long an operation takes. You give each timer a unique name, and may have up to 10,000 timers running on a given page. When you call console.timeEnd() with the same name, the browser will output the time, in milliseconds, that elapsed since the timer was started.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/time_static)
     */
    time(label?: string): void;
    /**
     * The **`console.timeEnd()`** static method stops a timer that was previously started by calling console.time().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/timeEnd_static)
     */
    timeEnd(label?: string): void;
    /**
     * The **`console.timeLog()`** static method logs the current value of a timer that was previously started by calling console.time().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/timeLog_static)
     */
    timeLog(label?: string, ...data: any[]): void;
    /** The **`console.timeStamp()`** static method adds a single marker to the browser's Performance tool (Firefox bug 1387528, Chrome). This lets you correlate a point in your code with the other events recorded in the timeline, such as layout and paint events. */
    timeStamp(label?: string): void;
    /**
     * The **`console.trace()`** static method outputs a stack trace to the console.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/trace_static)
     */
    trace(...data: any[]): void;
    /**
     * The **`console.warn()`** static method outputs a warning message to the console at the "warning" log level. The message is only displayed to the user if the console is configured to display warning output. In most cases, the log level is configured within the console UI. The message may receive special formatting, such as yellow colors and a warning icon.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/warn_static)
     */
    warn(...data: any[]): void;
}

declare var console: Console;

interface AudioDataOutputCallback {
    (output: AudioData): void;
}

interface BlobCallback {
    (blob: Blob | null): void;
}

interface CustomElementConstructor {
    new (...params: any[]): HTMLElement;
}

interface DecodeErrorCallback {
    (error: DOMException): void;
}

interface DecodeSuccessCallback {
    (decodedData: AudioBuffer): void;
}

interface EncodedAudioChunkOutputCallback {
    (output: EncodedAudioChunk, metadata?: EncodedAudioChunkMetadata): void;
}

interface EncodedVideoChunkOutputCallback {
    (chunk: EncodedVideoChunk, metadata?: EncodedVideoChunkMetadata): void;
}

interface ErrorCallback {
    (err: DOMException): void;
}

interface FileCallback {
    (file: File): void;
}

interface FileSystemEntriesCallback {
    (entries: FileSystemEntry[]): void;
}

interface FileSystemEntryCallback {
    (entry: FileSystemEntry): void;
}

interface FrameRequestCallback {
    (time: DOMHighResTimeStamp): void;
}

interface FunctionStringCallback {
    (data: string): void;
}

interface IdleRequestCallback {
    (deadline: IdleDeadline): void;
}

interface IntersectionObserverCallback {
    (entries: IntersectionObserverEntry[], observer: IntersectionObserver): void;
}

interface LockGrantedCallback<T> {
    (lock: Lock | null): T;
}

interface MediaSessionActionHandler {
    (details: MediaSessionActionDetails): void;
}

interface MutationCallback {
    (mutations: MutationRecord[], observer: MutationObserver): void;
}

interface NavigationInterceptHandler {
    (): void | PromiseLike<void>;
}

interface NavigationPrecommitHandler {
    (controller: NavigationPrecommitController): void | PromiseLike<void>;
}

interface NotificationPermissionCallback {
    (permission: NotificationPermission): void;
}

interface OnBeforeUnloadEventHandlerNonNull {
    (event: Event): string | null;
}

interface OnErrorEventHandlerNonNull {
    (event: Event | string, source?: string, lineno?: number, colno?: number, error?: Error): any;
}

interface PerformanceObserverCallback {
    (entries: PerformanceObserverEntryList, observer: PerformanceObserver): void;
}

interface PositionCallback {
    (position: GeolocationPosition): void;
}

interface PositionErrorCallback {
    (positionError: GeolocationPositionError): void;
}

interface QueuingStrategySize<T = any> {
    (chunk: T): number;
}

interface RTCPeerConnectionErrorCallback {
    (error: DOMException): void;
}

interface RTCSessionDescriptionCallback {
    (description: RTCSessionDescriptionInit): void;
}

interface RemotePlaybackAvailabilityCallback {
    (available: boolean): void;
}

interface ReportingObserverCallback {
    (reports: Report[], observer: ReportingObserver): void;
}

interface ResizeObserverCallback {
    (entries: ResizeObserverEntry[], observer: ResizeObserver): void;
}

interface SchedulerPostTaskCallback {
    (): any;
}

interface TransformerFlushCallback<O> {
    (controller: TransformStreamDefaultController<O>): void | PromiseLike<void>;
}

interface TransformerStartCallback<O> {
    (controller: TransformStreamDefaultController<O>): any;
}

interface TransformerTransformCallback<I, O> {
    (chunk: I, controller: TransformStreamDefaultController<O>): void | PromiseLike<void>;
}

interface UnderlyingSinkAbortCallback {
    (reason?: any): void | PromiseLike<void>;
}

interface UnderlyingSinkCloseCallback {
    (): void | PromiseLike<void>;
}

interface UnderlyingSinkStartCallback {
    (controller: WritableStreamDefaultController): any;
}

interface UnderlyingSinkWriteCallback<W> {
    (chunk: W, controller: WritableStreamDefaultController): void | PromiseLike<void>;
}

interface UnderlyingSourceCancelCallback {
    (reason?: any): void | PromiseLike<void>;
}

interface UnderlyingSourcePullCallback<R> {
    (controller: ReadableStreamController<R>): void | PromiseLike<void>;
}

interface UnderlyingSourceStartCallback<R> {
    (controller: ReadableStreamController<R>): any;
}

interface VideoFrameOutputCallback {
    (output: VideoFrame): void;
}

interface VideoFrameRequestCallback {
    (now: DOMHighResTimeStamp, metadata: VideoFrameCallbackMetadata): void;
}

interface ViewTransitionUpdateCallback {
    (): any;
}

interface VoidFunction {
    (): void;
}

interface WebCodecsErrorCallback {
    (error: DOMException): void;
}

interface HTMLElementTagNameMap {
    "a": HTMLAnchorElement;
    "abbr": HTMLElement;
    "address": HTMLElement;
    "area": HTMLAreaElement;
    "article": HTMLElement;
    "aside": HTMLElement;
    "audio": HTMLAudioElement;
    "b": HTMLElement;
    "base": HTMLBaseElement;
    "bdi": HTMLElement;
    "bdo": HTMLElement;
    "blockquote": HTMLQuoteElement;
    "body": HTMLBodyElement;
    "br": HTMLBRElement;
    "button": HTMLButtonElement;
    "canvas": HTMLCanvasElement;
    "caption": HTMLTableCaptionElement;
    "cite": HTMLElement;
    "code": HTMLElement;
    "col": HTMLTableColElement;
    "colgroup": HTMLTableColElement;
    "data": HTMLDataElement;
    "datalist": HTMLDataListElement;
    "dd": HTMLElement;
    "del": HTMLModElement;
    "details": HTMLDetailsElement;
    "dfn": HTMLElement;
    "dialog": HTMLDialogElement;
    "div": HTMLDivElement;
    "dl": HTMLDListElement;
    "dt": HTMLElement;
    "em": HTMLElement;
    "embed": HTMLEmbedElement;
    "fieldset": HTMLFieldSetElement;
    "figcaption": HTMLElement;
    "figure": HTMLElement;
    "footer": HTMLElement;
    "form": HTMLFormElement;
    "h1": HTMLHeadingElement;
    "h2": HTMLHeadingElement;
    "h3": HTMLHeadingElement;
    "h4": HTMLHeadingElement;
    "h5": HTMLHeadingElement;
    "h6": HTMLHeadingElement;
    "head": HTMLHeadElement;
    "header": HTMLElement;
    "hgroup": HTMLElement;
    "hr": HTMLHRElement;
    "html": HTMLHtmlElement;
    "i": HTMLElement;
    "iframe": HTMLIFrameElement;
    "img": HTMLImageElement;
    "input": HTMLInputElement;
    "ins": HTMLModElement;
    "kbd": HTMLElement;
    "label": HTMLLabelElement;
    "legend": HTMLLegendElement;
    "li": HTMLLIElement;
    "link": HTMLLinkElement;
    "main": HTMLElement;
    "map": HTMLMapElement;
    "mark": HTMLElement;
    "menu": HTMLMenuElement;
    "meta": HTMLMetaElement;
    "meter": HTMLMeterElement;
    "nav": HTMLElement;
    "noscript": HTMLElement;
    "object": HTMLObjectElement;
    "ol": HTMLOListElement;
    "optgroup": HTMLOptGroupElement;
    "option": HTMLOptionElement;
    "output": HTMLOutputElement;
    "p": HTMLParagraphElement;
    "picture": HTMLPictureElement;
    "pre": HTMLPreElement;
    "progress": HTMLProgressElement;
    "q": HTMLQuoteElement;
    "rp": HTMLElement;
    "rt": HTMLElement;
    "ruby": HTMLElement;
    "s": HTMLElement;
    "samp": HTMLElement;
    "script": HTMLScriptElement;
    "search": HTMLElement;
    "section": HTMLElement;
    "select": HTMLSelectElement;
    "slot": HTMLSlotElement;
    "small": HTMLElement;
    "source": HTMLSourceElement;
    "span": HTMLSpanElement;
    "strong": HTMLElement;
    "style": HTMLStyleElement;
    "sub": HTMLElement;
    "summary": HTMLElement;
    "sup": HTMLElement;
    "table": HTMLTableElement;
    "tbody": HTMLTableSectionElement;
    "td": HTMLTableCellElement;
    "template": HTMLTemplateElement;
    "textarea": HTMLTextAreaElement;
    "tfoot": HTMLTableSectionElement;
    "th": HTMLTableCellElement;
    "thead": HTMLTableSectionElement;
    "time": HTMLTimeElement;
    "title": HTMLTitleElement;
    "tr": HTMLTableRowElement;
    "track": HTMLTrackElement;
    "u": HTMLElement;
    "ul": HTMLUListElement;
    "var": HTMLElement;
    "video": HTMLVideoElement;
    "wbr": HTMLElement;
}

interface HTMLElementDeprecatedTagNameMap {
    "acronym": HTMLElement;
    "applet": HTMLUnknownElement;
    "basefont": HTMLElement;
    "bgsound": HTMLUnknownElement;
    "big": HTMLElement;
    "blink": HTMLUnknownElement;
    "center": HTMLElement;
    "dir": HTMLDirectoryElement;
    "font": HTMLFontElement;
    "frame": HTMLFrameElement;
    "frameset": HTMLFrameSetElement;
    "isindex": HTMLUnknownElement;
    "keygen": HTMLUnknownElement;
    "listing": HTMLPreElement;
    "marquee": HTMLMarqueeElement;
    "menuitem": HTMLElement;
    "multicol": HTMLUnknownElement;
    "nextid": HTMLUnknownElement;
    "nobr": HTMLElement;
    "noembed": HTMLElement;
    "noframes": HTMLElement;
    "param": HTMLParamElement;
    "plaintext": HTMLElement;
    "rb": HTMLElement;
    "rtc": HTMLElement;
    "spacer": HTMLUnknownElement;
    "strike": HTMLElement;
    "tt": HTMLElement;
    "xmp": HTMLPreElement;
}

interface SVGElementTagNameMap {
    "a": SVGAElement;
    "animate": SVGAnimateElement;
    "animateMotion": SVGAnimateMotionElement;
    "animateTransform": SVGAnimateTransformElement;
    "circle": SVGCircleElement;
    "clipPath": SVGClipPathElement;
    "defs": SVGDefsElement;
    "desc": SVGDescElement;
    "ellipse": SVGEllipseElement;
    "feBlend": SVGFEBlendElement;
    "feColorMatrix": SVGFEColorMatrixElement;
    "feComponentTransfer": SVGFEComponentTransferElement;
    "feComposite": SVGFECompositeElement;
    "feConvolveMatrix": SVGFEConvolveMatrixElement;
    "feDiffuseLighting": SVGFEDiffuseLightingElement;
    "feDisplacementMap": SVGFEDisplacementMapElement;
    "feDistantLight": SVGFEDistantLightElement;
    "feDropShadow": SVGFEDropShadowElement;
    "feFlood": SVGFEFloodElement;
    "feFuncA": SVGFEFuncAElement;
    "feFuncB": SVGFEFuncBElement;
    "feFuncG": SVGFEFuncGElement;
    "feFuncR": SVGFEFuncRElement;
    "feGaussianBlur": SVGFEGaussianBlurElement;
    "feImage": SVGFEImageElement;
    "feMerge": SVGFEMergeElement;
    "feMergeNode": SVGFEMergeNodeElement;
    "feMorphology": SVGFEMorphologyElement;
    "feOffset": SVGFEOffsetElement;
    "fePointLight": SVGFEPointLightElement;
    "feSpecularLighting": SVGFESpecularLightingElement;
    "feSpotLight": SVGFESpotLightElement;
    "feTile": SVGFETileElement;
    "feTurbulence": SVGFETurbulenceElement;
    "filter": SVGFilterElement;
    "foreignObject": SVGForeignObjectElement;
    "g": SVGGElement;
    "image": SVGImageElement;
    "line": SVGLineElement;
    "linearGradient": SVGLinearGradientElement;
    "marker": SVGMarkerElement;
    "mask": SVGMaskElement;
    "metadata": SVGMetadataElement;
    "mpath": SVGMPathElement;
    "path": SVGPathElement;
    "pattern": SVGPatternElement;
    "polygon": SVGPolygonElement;
    "polyline": SVGPolylineElement;
    "radialGradient": SVGRadialGradientElement;
    "rect": SVGRectElement;
    "script": SVGScriptElement;
    "set": SVGSetElement;
    "stop": SVGStopElement;
    "style": SVGStyleElement;
    "svg": SVGSVGElement;
    "switch": SVGSwitchElement;
    "symbol": SVGSymbolElement;
    "text": SVGTextElement;
    "textPath": SVGTextPathElement;
    "title": SVGTitleElement;
    "tspan": SVGTSpanElement;
    "use": SVGUseElement;
    "view": SVGViewElement;
}

interface MathMLElementTagNameMap {
    "a": MathMLElement;
    "annotation": MathMLElement;
    "annotation-xml": MathMLElement;
    "maction": MathMLElement;
    "math": MathMLElement;
    "merror": MathMLElement;
    "mfrac": MathMLElement;
    "mi": MathMLElement;
    "mmultiscripts": MathMLElement;
    "mn": MathMLElement;
    "mo": MathMLElement;
    "mover": MathMLElement;
    "mpadded": MathMLElement;
    "mphantom": MathMLElement;
    "mprescripts": MathMLElement;
    "mroot": MathMLElement;
    "mrow": MathMLElement;
    "ms": MathMLElement;
    "mspace": MathMLElement;
    "msqrt": MathMLElement;
    "mstyle": MathMLElement;
    "msub": MathMLElement;
    "msubsup": MathMLElement;
    "msup": MathMLElement;
    "mtable": MathMLElement;
    "mtd": MathMLElement;
    "mtext": MathMLElement;
    "mtr": MathMLElement;
    "munder": MathMLElement;
    "munderover": MathMLElement;
    "semantics": MathMLElement;
}

/** @deprecated Directly use HTMLElementTagNameMap or SVGElementTagNameMap as appropriate, instead. */
type ElementTagNameMap = HTMLElementTagNameMap & Pick<SVGElementTagNameMap, Exclude<keyof SVGElementTagNameMap, keyof HTMLElementTagNameMap>>;

declare var Audio: {
    new(src?: string): HTMLAudioElement;
};
declare var Image: {
    new(width?: number, height?: number): HTMLImageElement;
};
declare var Option: {
    new(text?: string, value?: string, defaultSelected?: boolean, selected?: boolean): HTMLOptionElement;
};
/**
 * @deprecated This is a legacy alias of `navigator`.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/navigator)
 */
declare var clientInformation: Navigator;
/**
 * The **`Window.closed`** read-only property indicates whether the referenced window is closed or not.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/closed)
 */
declare var closed: boolean;
/**
 * The **`cookieStore`** read-only property of the Window interface returns a reference to the CookieStore object for the current document context. This is an entry point for the Cookie Store API.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/cookieStore)
 */
declare var cookieStore: CookieStore;
/**
 * The **`customElements`** read-only property of the Window interface returns a reference to the CustomElementRegistry object, which can be used to register new custom elements and get information about previously registered custom elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/customElements)
 */
declare var customElements: CustomElementRegistry;
/**
 * The **`devicePixelRatio`** of Window interface returns the ratio of the resolution in physical pixels to the resolution in CSS pixels for the current display device.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/devicePixelRatio)
 */
declare var devicePixelRatio: number;
/**
 * **`window.document`** returns a reference to the document contained in the window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/document)
 */
declare var document: Document;
/**
 * The read-only Window property **`event`** returns the Event which is currently being handled by the site's code. Outside the context of an event handler, the value is always undefined.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/event)
 */
declare var event: Event | undefined;
/**
 * The **`external`** property of the Window API returns an instance of the External interface, which was intended to contain functions related to adding external search providers to the browser. However, this is now deprecated, and the contained methods are now dummy functions that do nothing as per spec.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/external)
 */
declare var external: External;
/**
 * The **`Window.frameElement`** property returns the element (such as <iframe> or <object>) in which the window is embedded.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/frameElement)
 */
declare var frameElement: Element | null;
/**
 * Returns the window itself, which is an array-like object, listing the direct sub-**`frames`** of the current window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/frames)
 */
declare var frames: WindowProxy;
/**
 * The **`Window.history`** read-only property returns a reference to the History object, which provides an interface for manipulating the browser session history (pages visited in the tab or frame that the current page is loaded in).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/history)
 */
declare var history: History;
/**
 * The read-only **`innerHeight`** property of the Window interface returns the interior height of the window in pixels, including the height of the horizontal scroll bar, if present.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/innerHeight)
 */
declare var innerHeight: number;
/**
 * The read-only Window property **`innerWidth`** returns the interior width of the window in pixels (that is, the width of the window's layout viewport). That includes the width of the vertical scroll bar, if one is present.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/innerWidth)
 */
declare var innerWidth: number;
/**
 * Returns the number of frames (either <frame> or <iframe> elements) in the window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/length)
 */
declare var length: number;
/**
 * The read-only **`location`** property of the Window interface returns a Location object with information about the current location of the document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/location)
 */
declare var location: Location;
/**
 * Returns the **`locationbar`** object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/locationbar)
 */
declare var locationbar: BarProp;
/**
 * Returns the **`menubar`** object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/menubar)
 */
declare var menubar: BarProp;
/**
 * The **`Window.name`** property gets/sets the name of the window's browsing context.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/name)
 */
/** @deprecated */
declare const name: void;
/**
 * The **`navigation`** read-only property of the Window interface returns the current window's associated Navigation object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/navigation)
 */
declare var navigation: Navigation;
/**
 * The **`Window.navigator`** read-only property returns a reference to the Navigator object, which has methods and properties about the application running the script.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/navigator)
 */
declare var navigator: Navigator;
/**
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/devicemotion_event)
 */
declare var ondevicemotion: ((this: Window, ev: DeviceMotionEvent) => any) | null;
/**
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/deviceorientation_event)
 */
declare var ondeviceorientation: ((this: Window, ev: DeviceOrientationEvent) => any) | null;
/**
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/deviceorientationabsolute_event)
 */
declare var ondeviceorientationabsolute: ((this: Window, ev: DeviceOrientationEvent) => any) | null;
/**
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/orientationchange_event)
 */
declare var onorientationchange: ((this: Window, ev: Event) => any) | null;
/**
 * The Window interface's **`opener`** property returns a reference to the window that opened the window, either with open(), or by navigating a link with a target attribute.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/opener)
 */
declare var opener: any;
/**
 * Returns the **`orientation`** in degrees (in 90-degree increments) of the viewport relative to the device's natural orientation.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/orientation)
 */
declare var orientation: number;
/**
 * The **`originAgentCluster`** read-only property of the Window interface returns true if this window belongs to an origin-keyed agent cluster: this means that the operating system has provided dedicated resources (for example an operating system process) to this window's origin that are not shared with windows from other origins.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/originAgentCluster)
 */
declare var originAgentCluster: boolean;
/**
 * The **`Window.outerHeight`** read-only property returns the height in pixels of the whole browser window, including any sidebar, window chrome, and window-resizing borders/handles.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/outerHeight)
 */
declare var outerHeight: number;
/**
 * **`Window.outerWidth`** read-only property returns the width of the outside of the browser window. It represents the width of the whole browser window including sidebar (if expanded), window chrome and window resizing borders/handles.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/outerWidth)
 */
declare var outerWidth: number;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollX) */
declare var pageXOffset: number;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollY) */
declare var pageYOffset: number;
/**
 * The **`Window.parent`** property is a reference to the parent of the current window or subframe.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/parent)
 */
declare var parent: WindowProxy;
/**
 * Returns the **`personalbar`** object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/personalbar)
 */
declare var personalbar: BarProp;
/**
 * The Window property **`screen`** returns a reference to the screen object associated with the window. The screen object, implementing the Screen interface, is a special object for inspecting properties of the screen on which the current window is being rendered.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screen)
 */
declare var screen: Screen;
/**
 * The **`Window.screenLeft`** read-only property returns the horizontal distance, in CSS pixels, from the left border of the user's browser viewport to the left side of the screen.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenLeft)
 */
declare var screenLeft: number;
/**
 * The **`Window.screenTop`** read-only property returns the vertical distance, in CSS pixels, from the top border of the user's browser viewport to the top side of the screen.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenTop)
 */
declare var screenTop: number;
/**
 * The **`Window.screenX`** read-only property returns the horizontal distance, in CSS pixels, of the left border of the user's browser viewport to the left side of the screen.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenX)
 */
declare var screenX: number;
/**
 * The **`Window.screenY`** read-only property returns the vertical distance, in CSS pixels, of the top border of the user's browser viewport to the top edge of the screen.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/screenY)
 */
declare var screenY: number;
/**
 * The read-only **`scrollX`** property of the Window interface returns the number of pixels by which the document is currently scrolled horizontally. This value is subpixel precise in modern browsers, meaning that it isn't necessarily a whole number. You can get the number of pixels the document is scrolled vertically from the scrollY property.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollX)
 */
declare var scrollX: number;
/**
 * The read-only **`scrollY`** property of the Window interface returns the number of pixels by which the document is currently scrolled vertically. This value is subpixel precise in modern browsers, meaning that it isn't necessarily a whole number. You can get the number of pixels the document is scrolled horizontally from the scrollX property.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollY)
 */
declare var scrollY: number;
/**
 * Returns the **`scrollbars`** object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollbars)
 */
declare var scrollbars: BarProp;
/**
 * The **`Window.self`** read-only property returns the window itself, as a WindowProxy. It can be used with dot notation on a window object (that is, window.self) or standalone (self). The advantage of the standalone notation is that a similar notation exists for non-window contexts, such as in Web Workers. By using self, you can refer to the global scope in a way that will work not only in a window context (self will resolve to window.self) but also in a worker context (self will then resolve to WorkerGlobalScope.self).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/self)
 */
declare var self: Window & typeof globalThis;
/**
 * The **`speechSynthesis`** read-only property of the Window object returns a SpeechSynthesis object, which is the entry point into using Web Speech API speech synthesis functionality.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/speechSynthesis)
 */
declare var speechSynthesis: SpeechSynthesis;
/**
 * The **`status`** property of the Window interface was originally intended to set the text in the status bar at the bottom of the browser window. However, the HTML standard now requires setting window.status to have no effect on the text displayed in the status bar.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/status)
 */
declare var status: string;
/**
 * Returns the **`statusbar`** object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/statusbar)
 */
declare var statusbar: BarProp;
/**
 * Returns the **`toolbar`** object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/toolbar)
 */
declare var toolbar: BarProp;
/**
 * Returns a reference to the **`top`**most window in the window hierarchy.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/top)
 */
declare var top: WindowProxy | null;
/**
 * The **`visualViewport`** read-only property of the Window interface returns a VisualViewport object representing the visual viewport for a given window, or null if current document is not fully active.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/visualViewport)
 */
declare var visualViewport: VisualViewport | null;
/**
 * The **`window`** property of a Window object points to the window object itself.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/window)
 */
declare var window: Window & typeof globalThis;
/**
 * **`window.alert()`** instructs the browser to display a dialog with an optional message, and to wait until the user dismisses the dialog.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/alert)
 */
declare function alert(message?: any): void;
/**
 * The **`Window.blur()`** method does nothing.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/blur)
 */
declare function blur(): void;
/**
 * The **`window.cancelIdleCallback()`** method cancels a callback previously scheduled with window.requestIdleCallback().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/cancelIdleCallback)
 */
declare function cancelIdleCallback(handle: number): void;
/**
 * The **`Window.captureEvents()`** method does nothing. Its original behavior has been removed from the specification, but the method itself has been retained so as not to break code that calls it.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/captureEvents)
 */
declare function captureEvents(): void;
/**
 * The **`Window.close()`** method closes the current window, or the window on which it was called.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/close)
 */
declare function close(): void;
/**
 * **`window.confirm()`** instructs the browser to display a dialog with an optional message, and to wait until the user either confirms or cancels the dialog.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/confirm)
 */
declare function confirm(message?: string): boolean;
/**
 * Makes a request to bring the window to the front. It may fail due to user settings and the window isn't guaranteed to be frontmost before this method returns.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/focus)
 */
declare function focus(): void;
/**
 * The **`Window.getComputedStyle()`** method returns a live read-only CSSStyleProperties object containing the resolved values of all CSS properties of an element, after applying active stylesheets and resolving any computation those values may contain.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/getComputedStyle)
 */
declare function getComputedStyle(elt: Element, pseudoElt?: string | null): CSSStyleDeclaration;
/**
 * The **`getSelection()`** method of the Window interface returns the Selection object associated with the window's document, representing the range of text selected by the user or the current position of the caret.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/getSelection)
 */
declare function getSelection(): Selection | null;
/**
 * The Window interface's **`matchMedia()`** method returns a new MediaQueryList object that can then be used to determine if the document matches the media query string, as well as to monitor the document to detect when it matches (or stops matching) that media query.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/matchMedia)
 */
declare function matchMedia(query: string): MediaQueryList;
/**
 * The **`moveBy()`** method of the Window interface moves the current window by a specified amount.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/moveBy)
 */
declare function moveBy(x: number, y: number): void;
/**
 * The **`moveTo()`** method of the Window interface moves the current window to the specified coordinates.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/moveTo)
 */
declare function moveTo(x: number, y: number): void;
/**
 * The **`open()`** method of the Window interface loads a specified resource into a new or existing browsing context (that is, a tab, a window, or an iframe) under a specified name.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/open)
 */
declare function open(url?: string | URL, target?: string, features?: string): WindowProxy | null;
/**
 * The **`window.postMessage()`** method safely enables cross-origin communication between Window objects; e.g., between a page and a pop-up that it spawned, or between a page and an iframe embedded within it.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/postMessage)
 */
declare function postMessage(message: any, targetOrigin: string, transfer?: Transferable[]): void;
declare function postMessage(message: any, options?: WindowPostMessageOptions): void;
/**
 * Opens the **`print`** dialog to print the current document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/print)
 */
declare function print(): void;
/**
 * **`window.prompt()`** instructs the browser to display a dialog with an optional message prompting the user to input some text, and to wait until the user either submits the text or cancels the dialog.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/prompt)
 */
declare function prompt(message?: string, _default?: string): string | null;
/**
 * Releases the window from trapping events of a specific type.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/releaseEvents)
 */
declare function releaseEvents(): void;
/**
 * The **`window.requestIdleCallback()`** method queues a function to be called during a browser's idle periods. This enables developers to perform background and low priority work on the main thread, without impacting latency-critical events such as animation and input response. Functions are generally called in first-in-first-out order; however, callbacks which have a timeout specified may be called out-of-order if necessary in order to run them before the timeout elapses.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/requestIdleCallback)
 */
declare function requestIdleCallback(callback: IdleRequestCallback, options?: IdleRequestOptions): number;
/**
 * The **`Window.resizeBy()`** method resizes the current window by a specified amount.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/resizeBy)
 */
declare function resizeBy(x: number, y: number): void;
/**
 * The **`Window.resizeTo()`** method dynamically resizes the window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/resizeTo)
 */
declare function resizeTo(width: number, height: number): void;
/**
 * The **`Window.scroll()`** method scrolls the window to a particular place in the document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scroll)
 */
declare function scroll(options?: ScrollToOptions): void;
declare function scroll(x: number, y: number): void;
/**
 * The **`Window.scrollBy()`** method scrolls the document in the window by the given amount.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollBy)
 */
declare function scrollBy(options?: ScrollToOptions): void;
declare function scrollBy(x: number, y: number): void;
/**
 * **`Window.scrollTo()`** scrolls to a particular set of coordinates in the document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scrollTo)
 */
declare function scrollTo(options?: ScrollToOptions): void;
declare function scrollTo(x: number, y: number): void;
/**
 * The **`window.stop()`** stops further resource loading in the current browsing context, equivalent to the stop button in the browser.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/stop)
 */
declare function stop(): void;
declare function toString(): string;
/**
 * The **`dispatchEvent()`** method of the EventTarget sends an Event to the object, (synchronously) invoking the affected event listeners in the appropriate order. The normal event processing rules (including the capturing and optional bubbling phase) also apply to events dispatched manually with dispatchEvent().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventTarget/dispatchEvent)
 */
declare function dispatchEvent(event: Event): boolean;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/DedicatedWorkerGlobalScope/cancelAnimationFrame) */
declare function cancelAnimationFrame(handle: number): void;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/DedicatedWorkerGlobalScope/requestAnimationFrame) */
declare function requestAnimationFrame(callback: FrameRequestCallback): number;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/abort_event) */
declare var onabort: ((this: Window, ev: UIEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationcancel_event) */
declare var onanimationcancel: ((this: Window, ev: AnimationEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationend_event) */
declare var onanimationend: ((this: Window, ev: AnimationEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationiteration_event) */
declare var onanimationiteration: ((this: Window, ev: AnimationEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationstart_event) */
declare var onanimationstart: ((this: Window, ev: AnimationEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/auxclick_event) */
declare var onauxclick: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/beforeinput_event) */
declare var onbeforeinput: ((this: Window, ev: InputEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/beforematch_event) */
declare var onbeforematch: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/beforetoggle_event) */
declare var onbeforetoggle: ((this: Window, ev: ToggleEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/blur_event) */
declare var onblur: ((this: Window, ev: FocusEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/cancel_event) */
declare var oncancel: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/canplay_event) */
declare var oncanplay: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/canplaythrough_event) */
declare var oncanplaythrough: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/change_event) */
declare var onchange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/click_event) */
declare var onclick: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/close_event) */
declare var onclose: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/command_event) */
declare var oncommand: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/contextlost_event) */
declare var oncontextlost: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/contextmenu_event) */
declare var oncontextmenu: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/contextrestored_event) */
declare var oncontextrestored: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/copy_event) */
declare var oncopy: ((this: Window, ev: ClipboardEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/cuechange_event) */
declare var oncuechange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/cut_event) */
declare var oncut: ((this: Window, ev: ClipboardEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/dblclick_event) */
declare var ondblclick: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/drag_event) */
declare var ondrag: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragend_event) */
declare var ondragend: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragenter_event) */
declare var ondragenter: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragleave_event) */
declare var ondragleave: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragover_event) */
declare var ondragover: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragstart_event) */
declare var ondragstart: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/drop_event) */
declare var ondrop: ((this: Window, ev: DragEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/durationchange_event) */
declare var ondurationchange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/emptied_event) */
declare var onemptied: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/ended_event) */
declare var onended: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/error_event) */
declare var onerror: OnErrorEventHandler;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/focus_event) */
declare var onfocus: ((this: Window, ev: FocusEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/formdata_event) */
declare var onformdata: ((this: Window, ev: FormDataEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/gotpointercapture_event) */
declare var ongotpointercapture: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/input_event) */
declare var oninput: ((this: Window, ev: InputEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/invalid_event) */
declare var oninvalid: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/keydown_event) */
declare var onkeydown: ((this: Window, ev: KeyboardEvent) => any) | null;
/**
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/keypress_event)
 */
declare var onkeypress: ((this: Window, ev: KeyboardEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/keyup_event) */
declare var onkeyup: ((this: Window, ev: KeyboardEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/load_event) */
declare var onload: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loadeddata_event) */
declare var onloadeddata: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loadedmetadata_event) */
declare var onloadedmetadata: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loadstart_event) */
declare var onloadstart: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/lostpointercapture_event) */
declare var onlostpointercapture: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mousedown_event) */
declare var onmousedown: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseenter_event) */
declare var onmouseenter: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseleave_event) */
declare var onmouseleave: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mousemove_event) */
declare var onmousemove: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseout_event) */
declare var onmouseout: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseover_event) */
declare var onmouseover: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseup_event) */
declare var onmouseup: ((this: Window, ev: MouseEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/paste_event) */
declare var onpaste: ((this: Window, ev: ClipboardEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/pause_event) */
declare var onpause: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/play_event) */
declare var onplay: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/playing_event) */
declare var onplaying: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointercancel_event) */
declare var onpointercancel: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerdown_event) */
declare var onpointerdown: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerenter_event) */
declare var onpointerenter: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerleave_event) */
declare var onpointerleave: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointermove_event) */
declare var onpointermove: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerout_event) */
declare var onpointerout: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerover_event) */
declare var onpointerover: ((this: Window, ev: PointerEvent) => any) | null;
/**
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerrawupdate_event)
 */
declare var onpointerrawupdate: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerup_event) */
declare var onpointerup: ((this: Window, ev: PointerEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/progress_event) */
declare var onprogress: ((this: Window, ev: ProgressEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/ratechange_event) */
declare var onratechange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/reset_event) */
declare var onreset: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/resize_event) */
declare var onresize: ((this: Window, ev: UIEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/scroll_event) */
declare var onscroll: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/scrollend_event) */
declare var onscrollend: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/securitypolicyviolation_event) */
declare var onsecuritypolicyviolation: ((this: Window, ev: SecurityPolicyViolationEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/seeked_event) */
declare var onseeked: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/seeking_event) */
declare var onseeking: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/select_event) */
declare var onselect: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/selectionchange_event) */
declare var onselectionchange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/selectstart_event) */
declare var onselectstart: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement/slotchange_event) */
declare var onslotchange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/stalled_event) */
declare var onstalled: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/submit_event) */
declare var onsubmit: ((this: Window, ev: SubmitEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/suspend_event) */
declare var onsuspend: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/timeupdate_event) */
declare var ontimeupdate: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/toggle_event) */
declare var ontoggle: ((this: Window, ev: ToggleEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchcancel_event) */
declare var ontouchcancel: ((this: Window, ev: TouchEvent) => any) | null | undefined;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchend_event) */
declare var ontouchend: ((this: Window, ev: TouchEvent) => any) | null | undefined;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchmove_event) */
declare var ontouchmove: ((this: Window, ev: TouchEvent) => any) | null | undefined;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchstart_event) */
declare var ontouchstart: ((this: Window, ev: TouchEvent) => any) | null | undefined;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitioncancel_event) */
declare var ontransitioncancel: ((this: Window, ev: TransitionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionend_event) */
declare var ontransitionend: ((this: Window, ev: TransitionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionrun_event) */
declare var ontransitionrun: ((this: Window, ev: TransitionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionstart_event) */
declare var ontransitionstart: ((this: Window, ev: TransitionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/volumechange_event) */
declare var onvolumechange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/waiting_event) */
declare var onwaiting: ((this: Window, ev: Event) => any) | null;
/**
 * @deprecated This is a legacy alias of `onanimationend`.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationend_event)
 */
declare var onwebkitanimationend: ((this: Window, ev: Event) => any) | null;
/**
 * @deprecated This is a legacy alias of `onanimationiteration`.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationiteration_event)
 */
declare var onwebkitanimationiteration: ((this: Window, ev: Event) => any) | null;
/**
 * @deprecated This is a legacy alias of `onanimationstart`.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationstart_event)
 */
declare var onwebkitanimationstart: ((this: Window, ev: Event) => any) | null;
/**
 * @deprecated This is a legacy alias of `ontransitionend`.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionend_event)
 */
declare var onwebkittransitionend: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/wheel_event) */
declare var onwheel: ((this: Window, ev: WheelEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/afterprint_event) */
declare var onafterprint: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/beforeprint_event) */
declare var onbeforeprint: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/beforeunload_event) */
declare var onbeforeunload: ((this: Window, ev: BeforeUnloadEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/gamepadconnected_event) */
declare var ongamepadconnected: ((this: Window, ev: GamepadEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/gamepaddisconnected_event) */
declare var ongamepaddisconnected: ((this: Window, ev: GamepadEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/hashchange_event) */
declare var onhashchange: ((this: Window, ev: HashChangeEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/languagechange_event) */
declare var onlanguagechange: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/message_event) */
declare var onmessage: ((this: Window, ev: MessageEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/messageerror_event) */
declare var onmessageerror: ((this: Window, ev: MessageEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/offline_event) */
declare var onoffline: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/online_event) */
declare var ononline: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pagehide_event) */
declare var onpagehide: ((this: Window, ev: PageTransitionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pagereveal_event) */
declare var onpagereveal: ((this: Window, ev: PageRevealEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pageshow_event) */
declare var onpageshow: ((this: Window, ev: PageTransitionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/pageswap_event) */
declare var onpageswap: ((this: Window, ev: PageSwapEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/popstate_event) */
declare var onpopstate: ((this: Window, ev: PopStateEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/rejectionhandled_event) */
declare var onrejectionhandled: ((this: Window, ev: PromiseRejectionEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/storage_event) */
declare var onstorage: ((this: Window, ev: StorageEvent) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/unhandledrejection_event) */
declare var onunhandledrejection: ((this: Window, ev: PromiseRejectionEvent) => any) | null;
/**
 * @deprecated The unload event is not reliable, consider visibilitychange or pagehide events.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/unload_event)
 */
declare var onunload: ((this: Window, ev: Event) => any) | null;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/localStorage) */
declare var localStorage: Storage;
/**
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/caches)
 */
declare var caches: CacheStorage;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/crossOriginIsolated) */
declare var crossOriginIsolated: boolean;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/crypto) */
declare var crypto: Crypto;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/indexedDB) */
declare var indexedDB: IDBFactory;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/isSecureContext) */
declare var isSecureContext: boolean;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/origin) */
declare var origin: string;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/performance) */
declare var performance: Performance;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/scheduler) */
declare var scheduler: Scheduler;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/atob) */
declare function atob(data: string): string;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/btoa) */
declare function btoa(data: string): string;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/clearInterval) */
declare function clearInterval(id: number | undefined): void;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/clearTimeout) */
declare function clearTimeout(id: number | undefined): void;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/createImageBitmap) */
declare function createImageBitmap(image: ImageBitmapSource, options?: ImageBitmapOptions): Promise<ImageBitmap>;
declare function createImageBitmap(image: ImageBitmapSource, sx: number, sy: number, sw: number, sh: number, options?: ImageBitmapOptions): Promise<ImageBitmap>;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/fetch) */
declare function fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/queueMicrotask) */
declare function queueMicrotask(callback: VoidFunction): void;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/reportError) */
declare function reportError(e: any): void;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/setInterval) */
declare function setInterval(handler: TimerHandler, timeout?: number, ...arguments: any[]): number;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/setTimeout) */
declare function setTimeout(handler: TimerHandler, timeout?: number, ...arguments: any[]): number;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/structuredClone) */
declare function structuredClone<T = any>(value: T, options?: StructuredSerializeOptions): T;
/** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Window/sessionStorage) */
declare var sessionStorage: Storage;
declare function addEventListener<K extends keyof WindowEventMap>(type: K, listener: (this: Window, ev: WindowEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
declare function addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
declare function removeEventListener<K extends keyof WindowEventMap>(type: K, listener: (this: Window, ev: WindowEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
declare function removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
type AlgorithmIdentifier = Algorithm | string;
type AllowSharedBufferSource = ArrayBufferLike | ArrayBufferView<ArrayBufferLike>;
type AutoFill = AutoFillBase | `${OptionalPrefixToken<AutoFillSection>}${OptionalPrefixToken<AutoFillAddressKind>}${AutoFillField}${OptionalPostfixToken<AutoFillCredentialField>}`;
type AutoFillField = AutoFillNormalField | `${OptionalPrefixToken<AutoFillContactKind>}${AutoFillContactField}`;
type AutoFillSection = `section-${string}`;
type Base64URLString = string;
type BigInteger = Uint8Array<ArrayBuffer>;
type BlobPart = BufferSource | Blob | string;
type BodyInit = ReadableStream | XMLHttpRequestBodyInit;
type BufferSource = ArrayBufferView<ArrayBuffer> | ArrayBuffer;
type COSEAlgorithmIdentifier = number;
type CSSKeywordish = string | CSSKeywordValue;
type CSSNumberish = number | CSSNumericValue;
type CSSPerspectiveValue = CSSNumericValue | CSSKeywordish;
type CSSUnparsedSegment = string | CSSVariableReferenceValue;
type CanvasImageSource = HTMLOrSVGImageElement | HTMLVideoElement | HTMLCanvasElement | ImageBitmap | OffscreenCanvas | VideoFrame;
type ClipboardItemData = Promise<string | Blob>;
type ClipboardItems = ClipboardItem[];
type ConstrainBoolean = boolean | ConstrainBooleanParameters;
type ConstrainBooleanOrDOMString = boolean | string | ConstrainBooleanOrDOMStringParameters;
type ConstrainDOMString = string | string[] | ConstrainDOMStringParameters;
type ConstrainDouble = number | ConstrainDoubleRange;
type ConstrainULong = number | ConstrainULongRange;
type CookieList = CookieListItem[];
type DOMHighResTimeStamp = number;
type EpochTimeStamp = number;
type EventListenerOrEventListenerObject = EventListener | EventListenerObject;
type FileSystemWriteChunkType = BufferSource | Blob | string | WriteParams;
type Float32List = Float32Array<ArrayBufferLike> | GLfloat[];
type FormDataEntryValue = File | string;
type GLbitfield = number;
type GLboolean = boolean;
type GLclampf = number;
type GLenum = number;
type GLfloat = number;
type GLint = number;
type GLint64 = number;
type GLintptr = number;
type GLsizei = number;
type GLsizeiptr = number;
type GLuint = number;
type GLuint64 = number;
type GPUBindingResource = GPUSampler | GPUTexture | GPUTextureView | GPUBuffer | GPUBufferBinding | GPUExternalTexture;
type GPUBufferDynamicOffset = number;
type GPUBufferUsageFlags = number;
type GPUColor = number[] | GPUColorDict;
type GPUColorWriteFlags = number;
type GPUCopyExternalImageSource = ImageBitmap | ImageData | HTMLImageElement | HTMLVideoElement | VideoFrame | HTMLCanvasElement | OffscreenCanvas;
type GPUDepthBias = number;
type GPUExtent3D = GPUIntegerCoordinate[] | GPUExtent3DDict;
type GPUFlagsConstant = number;
type GPUIndex32 = number;
type GPUIntegerCoordinate = number;
type GPUIntegerCoordinateOut = number;
type GPUMapModeFlags = number;
type GPUOrigin2D = GPUIntegerCoordinate[] | GPUOrigin2DDict;
type GPUOrigin3D = GPUIntegerCoordinate[] | GPUOrigin3DDict;
type GPUPipelineConstantValue = number;
type GPUSampleMask = number;
type GPUShaderStageFlags = number;
type GPUSignedOffset32 = number;
type GPUSize32 = number;
type GPUSize32Out = number;
type GPUSize64 = number;
type GPUSize64Out = number;
type GPUStencilValue = number;
type GPUTextureUsageFlags = number;
type HTMLOrSVGImageElement = HTMLImageElement | SVGImageElement;
type HTMLOrSVGScriptElement = HTMLScriptElement | SVGScriptElement;
type HashAlgorithmIdentifier = AlgorithmIdentifier;
type HeadersInit = [string, string][] | Record<string, string> | Headers;
type IDBValidKey = number | string | Date | BufferSource | IDBValidKey[];
type ImageBitmapSource = CanvasImageSource | Blob | ImageData;
type ImageBufferSource = AllowSharedBufferSource | ReadableStream;
type ImageDataArray = Uint8ClampedArray<ArrayBuffer>;
type Int32List = Int32Array<ArrayBufferLike> | GLint[];
type LineAndPositionSetting = number | AutoKeyword;
type MediaProvider = MediaStream | MediaSource | Blob;
type MessageEventSource = WindowProxy | MessagePort | ServiceWorker;
type MutationRecordType = "attributes" | "characterData" | "childList";
type NamedCurve = string;
type OffscreenRenderingContext = OffscreenCanvasRenderingContext2D | ImageBitmapRenderingContext | WebGLRenderingContext | WebGL2RenderingContext | GPUCanvasContext;
type OnBeforeUnloadEventHandler = OnBeforeUnloadEventHandlerNonNull | null;
type OnErrorEventHandler = OnErrorEventHandlerNonNull | null;
type OptionalPostfixToken<T extends string> = ` ${T}` | "";
type OptionalPrefixToken<T extends string> = `${T} ` | "";
type PerformanceEntryList = PerformanceEntry[];
type PublicKeyCredentialClientCapabilities = Record<string, boolean>;
type RTCRtpReceiverTransform = RTCRtpScriptTransform;
type RTCRtpSenderTransform = RTCRtpScriptTransform;
type ReadableStreamController<T> = ReadableStreamDefaultController<T> | ReadableByteStreamController;
type ReadableStreamReadResult<T> = ReadableStreamReadValueResult<T> | ReadableStreamReadDoneResult<T>;
type ReadableStreamReader<T> = ReadableStreamDefaultReader<T> | ReadableStreamBYOBReader;
type RenderingContext = CanvasRenderingContext2D | ImageBitmapRenderingContext | WebGLRenderingContext | WebGL2RenderingContext | GPUCanvasContext;
type ReportList = Report[];
type RequestInfo = Request | string;
type SanitizerAttribute = string | SanitizerAttributeNamespace;
type SanitizerElement = string | SanitizerElementNamespace;
type SanitizerElementWithAttributes = string | SanitizerElementNamespaceWithAttributes;
type SelectionDirection = "forward" | "backward" | "none";
type TexImageSource = ImageBitmap | ImageData | HTMLImageElement | HTMLCanvasElement | HTMLVideoElement | OffscreenCanvas | VideoFrame;
type TimerHandler = string | Function;
type Transferable = OffscreenCanvas | ImageBitmap | MessagePort | MediaSourceHandle | ReadableStream | WritableStream | TransformStream | AudioData | VideoFrame | RTCDataChannel | ArrayBuffer;
type URLPatternInput = string | URLPatternInit;
type Uint32List = Uint32Array<ArrayBufferLike> | GLuint[];
type VibratePattern = number | number[];
type WindowProxy = Window;
type XMLHttpRequestBodyInit = Blob | BufferSource | FormData | URLSearchParams | string;
type AacBitstreamFormat = "aac" | "adts";
type AlignSetting = "center" | "end" | "left" | "right" | "start";
type AlphaOption = "discard" | "keep";
type AnimationPlayState = "finished" | "idle" | "paused" | "running";
type AnimationReplaceState = "active" | "persisted" | "removed";
type AppendMode = "segments" | "sequence";
type AttestationConveyancePreference = "direct" | "enterprise" | "indirect" | "none";
type AudioContextLatencyCategory = "balanced" | "interactive" | "playback";
type AudioContextState = "closed" | "interrupted" | "running" | "suspended";
type AudioSampleFormat = "f32" | "f32-planar" | "s16" | "s16-planar" | "s32" | "s32-planar" | "u8" | "u8-planar";
type AuthenticatorAttachment = "cross-platform" | "platform";
type AuthenticatorTransport = "ble" | "hybrid" | "internal" | "nfc" | "usb";
type AutoFillAddressKind = "billing" | "shipping";
type AutoFillBase = "" | "off" | "on";
type AutoFillContactField = "email" | "tel" | "tel-area-code" | "tel-country-code" | "tel-extension" | "tel-local" | "tel-local-prefix" | "tel-local-suffix" | "tel-national";
type AutoFillContactKind = "home" | "mobile" | "work";
type AutoFillCredentialField = "webauthn";
type AutoFillNormalField = "additional-name" | "address-level1" | "address-level2" | "address-level3" | "address-level4" | "address-line1" | "address-line2" | "address-line3" | "bday-day" | "bday-month" | "bday-year" | "cc-csc" | "cc-exp" | "cc-exp-month" | "cc-exp-year" | "cc-family-name" | "cc-given-name" | "cc-name" | "cc-number" | "cc-type" | "country" | "country-name" | "current-password" | "family-name" | "given-name" | "honorific-prefix" | "honorific-suffix" | "name" | "new-password" | "one-time-code" | "organization" | "postal-code" | "street-address" | "transaction-amount" | "transaction-currency" | "username";
type AutoKeyword = "auto";
type AutomationRate = "a-rate" | "k-rate";
type AvcBitstreamFormat = "annexb" | "avc";
type BinaryType = "arraybuffer" | "blob";
type BiquadFilterType = "allpass" | "bandpass" | "highpass" | "highshelf" | "lowpass" | "lowshelf" | "notch" | "peaking";
type BitrateMode = "constant" | "variable";
type CSSMathOperator = "clamp" | "invert" | "max" | "min" | "negate" | "product" | "sum";
type CSSNumericBaseType = "angle" | "flex" | "frequency" | "length" | "percent" | "resolution" | "time";
type CanPlayTypeResult = "" | "maybe" | "probably";
type CanvasDirection = "inherit" | "ltr" | "rtl";
type CanvasFillRule = "evenodd" | "nonzero";
type CanvasFontKerning = "auto" | "none" | "normal";
type CanvasFontStretch = "condensed" | "expanded" | "extra-condensed" | "extra-expanded" | "normal" | "semi-condensed" | "semi-expanded" | "ultra-condensed" | "ultra-expanded";
type CanvasFontVariantCaps = "all-petite-caps" | "all-small-caps" | "normal" | "petite-caps" | "small-caps" | "titling-caps" | "unicase";
type CanvasLineCap = "butt" | "round" | "square";
type CanvasLineJoin = "bevel" | "miter" | "round";
type CanvasTextAlign = "center" | "end" | "left" | "right" | "start";
type CanvasTextBaseline = "alphabetic" | "bottom" | "hanging" | "ideographic" | "middle" | "top";
type CanvasTextRendering = "auto" | "geometricPrecision" | "optimizeLegibility" | "optimizeSpeed";
type ChannelCountMode = "clamped-max" | "explicit" | "max";
type ChannelInterpretation = "discrete" | "speakers";
type ClientTypes = "all" | "sharedworker" | "window" | "worker";
type CodecState = "closed" | "configured" | "unconfigured";
type ColorGamut = "p3" | "rec2020" | "srgb";
type ColorSpaceConversion = "default" | "none";
type CompositeOperation = "accumulate" | "add" | "replace";
type CompositeOperationOrAuto = "accumulate" | "add" | "auto" | "replace";
type CompressionFormat = "deflate" | "deflate-raw" | "gzip";
type CookieSameSite = "lax" | "none" | "strict";
type CredentialMediationRequirement = "conditional" | "optional" | "required" | "silent";
type DOMParserSupportedType = "application/xhtml+xml" | "application/xml" | "image/svg+xml" | "text/html" | "text/xml";
type DirectionSetting = "" | "lr" | "rl";
type DisplayCaptureSurfaceType = "browser" | "monitor" | "window";
type DistanceModelType = "exponential" | "inverse" | "linear";
type DocumentReadyState = "complete" | "interactive" | "loading";
type DocumentVisibilityState = "hidden" | "visible";
type EncodedAudioChunkType = "delta" | "key";
type EncodedVideoChunkType = "delta" | "key";
type EndOfStreamError = "decode" | "network";
type EndingType = "native" | "transparent";
type FileSystemHandleKind = "directory" | "file";
type FillLightMode = "auto" | "flash" | "off";
type FillMode = "auto" | "backwards" | "both" | "forwards" | "none";
type FontDisplay = "auto" | "block" | "fallback" | "optional" | "swap";
type FontFaceLoadStatus = "error" | "loaded" | "loading" | "unloaded";
type FontFaceSetLoadStatus = "loaded" | "loading";
type FullscreenNavigationUI = "auto" | "hide" | "show";
type GPUAddressMode = "clamp-to-edge" | "mirror-repeat" | "repeat";
type GPUAutoLayoutMode = "auto";
type GPUBlendFactor = "constant" | "dst" | "dst-alpha" | "one" | "one-minus-constant" | "one-minus-dst" | "one-minus-dst-alpha" | "one-minus-src" | "one-minus-src-alpha" | "src" | "src-alpha" | "src-alpha-saturated" | "zero";
type GPUBlendOperation = "add" | "max" | "min" | "reverse-subtract" | "subtract";
type GPUBufferBindingType = "read-only-storage" | "storage" | "uniform";
type GPUBufferMapState = "mapped" | "pending" | "unmapped";
type GPUCanvasAlphaMode = "opaque" | "premultiplied";
type GPUCanvasToneMappingMode = "extended" | "standard";
type GPUCompareFunction = "always" | "equal" | "greater" | "greater-equal" | "less" | "less-equal" | "never" | "not-equal";
type GPUCompilationMessageType = "error" | "info" | "warning";
type GPUCullMode = "back" | "front" | "none";
type GPUDeviceLostReason = "destroyed" | "unknown";
type GPUErrorFilter = "internal" | "out-of-memory" | "validation";
type GPUFeatureName = "bgra8unorm-storage" | "clip-distances" | "core-features-and-limits" | "depth-clip-control" | "depth32float-stencil8" | "dual-source-blending" | "float32-blendable" | "float32-filterable" | "indirect-first-instance" | "primitive-index" | "rg11b10ufloat-renderable" | "shader-f16" | "subgroups" | "texture-compression-astc" | "texture-compression-astc-sliced-3d" | "texture-compression-bc" | "texture-compression-bc-sliced-3d" | "texture-compression-etc2" | "texture-formats-tier1" | "timestamp-query";
type GPUFilterMode = "linear" | "nearest";
type GPUFrontFace = "ccw" | "cw";
type GPUIndexFormat = "uint16" | "uint32";
type GPULoadOp = "clear" | "load";
type GPUMipmapFilterMode = "linear" | "nearest";
type GPUPipelineErrorReason = "internal" | "validation";
type GPUPowerPreference = "high-performance" | "low-power";
type GPUPrimitiveTopology = "line-list" | "line-strip" | "point-list" | "triangle-list" | "triangle-strip";
type GPUQueryType = "occlusion" | "timestamp";
type GPUSamplerBindingType = "comparison" | "filtering" | "non-filtering";
type GPUStencilOperation = "decrement-clamp" | "decrement-wrap" | "increment-clamp" | "increment-wrap" | "invert" | "keep" | "replace" | "zero";
type GPUStorageTextureAccess = "read-only" | "read-write" | "write-only";
type GPUStoreOp = "discard" | "store";
type GPUTextureAspect = "all" | "depth-only" | "stencil-only";
type GPUTextureDimension = "1d" | "2d" | "3d";
type GPUTextureFormat = "astc-10x10-unorm" | "astc-10x10-unorm-srgb" | "astc-10x5-unorm" | "astc-10x5-unorm-srgb" | "astc-10x6-unorm" | "astc-10x6-unorm-srgb" | "astc-10x8-unorm" | "astc-10x8-unorm-srgb" | "astc-12x10-unorm" | "astc-12x10-unorm-srgb" | "astc-12x12-unorm" | "astc-12x12-unorm-srgb" | "astc-4x4-unorm" | "astc-4x4-unorm-srgb" | "astc-5x4-unorm" | "astc-5x4-unorm-srgb" | "astc-5x5-unorm" | "astc-5x5-unorm-srgb" | "astc-6x5-unorm" | "astc-6x5-unorm-srgb" | "astc-6x6-unorm" | "astc-6x6-unorm-srgb" | "astc-8x5-unorm" | "astc-8x5-unorm-srgb" | "astc-8x6-unorm" | "astc-8x6-unorm-srgb" | "astc-8x8-unorm" | "astc-8x8-unorm-srgb" | "bc1-rgba-unorm" | "bc1-rgba-unorm-srgb" | "bc2-rgba-unorm" | "bc2-rgba-unorm-srgb" | "bc3-rgba-unorm" | "bc3-rgba-unorm-srgb" | "bc4-r-snorm" | "bc4-r-unorm" | "bc5-rg-snorm" | "bc5-rg-unorm" | "bc6h-rgb-float" | "bc6h-rgb-ufloat" | "bc7-rgba-unorm" | "bc7-rgba-unorm-srgb" | "bgra8unorm" | "bgra8unorm-srgb" | "depth16unorm" | "depth24plus" | "depth24plus-stencil8" | "depth32float" | "depth32float-stencil8" | "eac-r11snorm" | "eac-r11unorm" | "eac-rg11snorm" | "eac-rg11unorm" | "etc2-rgb8a1unorm" | "etc2-rgb8a1unorm-srgb" | "etc2-rgb8unorm" | "etc2-rgb8unorm-srgb" | "etc2-rgba8unorm" | "etc2-rgba8unorm-srgb" | "r16float" | "r16sint" | "r16snorm" | "r16uint" | "r16unorm" | "r32float" | "r32sint" | "r32uint" | "r8sint" | "r8snorm" | "r8uint" | "r8unorm" | "rg11b10ufloat" | "rg16float" | "rg16sint" | "rg16snorm" | "rg16uint" | "rg16unorm" | "rg32float" | "rg32sint" | "rg32uint" | "rg8sint" | "rg8snorm" | "rg8uint" | "rg8unorm" | "rgb10a2uint" | "rgb10a2unorm" | "rgb9e5ufloat" | "rgba16float" | "rgba16sint" | "rgba16snorm" | "rgba16uint" | "rgba16unorm" | "rgba32float" | "rgba32sint" | "rgba32uint" | "rgba8sint" | "rgba8snorm" | "rgba8uint" | "rgba8unorm" | "rgba8unorm-srgb" | "stencil8";
type GPUTextureSampleType = "depth" | "float" | "sint" | "uint" | "unfilterable-float";
type GPUTextureViewDimension = "1d" | "2d" | "2d-array" | "3d" | "cube" | "cube-array";
type GPUVertexFormat = "float16" | "float16x2" | "float16x4" | "float32" | "float32x2" | "float32x3" | "float32x4" | "sint16" | "sint16x2" | "sint16x4" | "sint32" | "sint32x2" | "sint32x3" | "sint32x4" | "sint8" | "sint8x2" | "sint8x4" | "snorm16" | "snorm16x2" | "snorm16x4" | "snorm8" | "snorm8x2" | "snorm8x4" | "uint16" | "uint16x2" | "uint16x4" | "uint32" | "uint32x2" | "uint32x3" | "uint32x4" | "uint8" | "uint8x2" | "uint8x4" | "unorm10-10-10-2" | "unorm16" | "unorm16x2" | "unorm16x4" | "unorm8" | "unorm8x2" | "unorm8x4" | "unorm8x4-bgra";
type GPUVertexStepMode = "instance" | "vertex";
type GamepadHapticEffectType = "dual-rumble" | "trigger-rumble";
type GamepadHapticsResult = "complete" | "preempted";
type GamepadMappingType = "" | "standard" | "xr-standard";
type GlobalCompositeOperation = "color" | "color-burn" | "color-dodge" | "copy" | "darken" | "destination-atop" | "destination-in" | "destination-out" | "destination-over" | "difference" | "exclusion" | "hard-light" | "hue" | "lighten" | "lighter" | "luminosity" | "multiply" | "overlay" | "saturation" | "screen" | "soft-light" | "source-atop" | "source-in" | "source-out" | "source-over" | "xor";
type HardwareAcceleration = "no-preference" | "prefer-hardware" | "prefer-software";
type HdrMetadataType = "smpteSt2086" | "smpteSt2094-10" | "smpteSt2094-40";
type HighlightType = "grammar-error" | "highlight" | "spelling-error";
type IDBCursorDirection = "next" | "nextunique" | "prev" | "prevunique";
type IDBRequestReadyState = "done" | "pending";
type IDBTransactionDurability = "default" | "relaxed" | "strict";
type IDBTransactionMode = "readonly" | "readwrite" | "versionchange";
type ImageDataPixelFormat = "rgba-float16" | "rgba-unorm8";
type ImageOrientation = "flipY" | "from-image" | "none";
type ImageSmoothingQuality = "high" | "low" | "medium";
type InsertPosition = "afterbegin" | "afterend" | "beforebegin" | "beforeend";
type IterationCompositeOperation = "accumulate" | "replace";
type KeyFormat = "jwk" | "pkcs8" | "raw" | "spki";
type KeyType = "private" | "public" | "secret";
type KeyUsage = "decrypt" | "deriveBits" | "deriveKey" | "encrypt" | "sign" | "unwrapKey" | "verify" | "wrapKey";
type LatencyMode = "quality" | "realtime";
type LineAlignSetting = "center" | "end" | "start";
type LockMode = "exclusive" | "shared";
type LoginStatus = "logged-in" | "logged-out";
type MIDIPortConnectionState = "closed" | "open" | "pending";
type MIDIPortDeviceState = "connected" | "disconnected";
type MIDIPortType = "input" | "output";
type MediaDecodingType = "file" | "media-source" | "webrtc";
type MediaDeviceKind = "audioinput" | "audiooutput" | "videoinput";
type MediaEncodingType = "record" | "webrtc";
type MediaKeyMessageType = "individualization-request" | "license-release" | "license-renewal" | "license-request";
type MediaKeySessionClosedReason = "closed-by-application" | "hardware-context-reset" | "internal-error" | "release-acknowledged" | "resource-evicted";
type MediaKeySessionType = "persistent-license" | "temporary";
type MediaKeyStatus = "expired" | "internal-error" | "output-downscaled" | "output-restricted" | "released" | "status-pending" | "usable" | "usable-in-future";
type MediaKeysRequirement = "not-allowed" | "optional" | "required";
type MediaSessionAction = "nexttrack" | "pause" | "play" | "previoustrack" | "seekbackward" | "seekforward" | "seekto" | "skipad" | "stop";
type MediaSessionPlaybackState = "none" | "paused" | "playing";
type MediaStreamTrackState = "ended" | "live";
type NavigationFocusReset = "after-transition" | "manual";
type NavigationHistoryBehavior = "auto" | "push" | "replace";
type NavigationScrollBehavior = "after-transition" | "manual";
type NavigationTimingType = "back_forward" | "navigate" | "reload";
type NavigationType = "push" | "reload" | "replace" | "traverse";
type NotificationDirection = "auto" | "ltr" | "rtl";
type NotificationPermission = "default" | "denied" | "granted";
type OffscreenRenderingContextId = "2d" | "bitmaprenderer" | "webgl" | "webgl2" | "webgpu";
type OpusBitstreamFormat = "ogg" | "opus";
type OrientationLockType = "any" | "landscape" | "landscape-primary" | "landscape-secondary" | "natural" | "portrait" | "portrait-primary" | "portrait-secondary";
type OrientationType = "landscape-primary" | "landscape-secondary" | "portrait-primary" | "portrait-secondary";
type OscillatorType = "custom" | "sawtooth" | "sine" | "square" | "triangle";
type OverSampleType = "2x" | "4x" | "none";
type PanningModelType = "HRTF" | "equalpower";
type PaymentComplete = "fail" | "success" | "unknown";
type PaymentShippingType = "delivery" | "pickup" | "shipping";
type PermissionName = "camera" | "geolocation" | "microphone" | "midi" | "notifications" | "persistent-storage" | "push" | "screen-wake-lock" | "storage-access";
type PermissionState = "denied" | "granted" | "prompt";
type PlaybackDirection = "alternate" | "alternate-reverse" | "normal" | "reverse";
type PositionAlignSetting = "auto" | "center" | "line-left" | "line-right";
type PredefinedColorSpace = "display-p3" | "srgb";
type PremultiplyAlpha = "default" | "none" | "premultiply";
type PresentationStyle = "attachment" | "inline" | "unspecified";
type PublicKeyCredentialType = "public-key";
type PushEncryptionKeyName = "auth" | "p256dh";
type RTCBundlePolicy = "balanced" | "max-bundle" | "max-compat";
type RTCDataChannelState = "closed" | "closing" | "connecting" | "open";
type RTCDegradationPreference = "balanced" | "maintain-framerate" | "maintain-resolution";
type RTCDtlsRole = "client" | "server" | "unknown";
type RTCDtlsTransportState = "closed" | "connected" | "connecting" | "failed" | "new";
type RTCErrorDetailType = "data-channel-failure" | "dtls-failure" | "fingerprint-failure" | "hardware-encoder-error" | "hardware-encoder-not-available" | "sctp-failure" | "sdp-syntax-error";
type RTCIceCandidateType = "host" | "prflx" | "relay" | "srflx";
type RTCIceComponent = "rtcp" | "rtp";
type RTCIceConnectionState = "checking" | "closed" | "completed" | "connected" | "disconnected" | "failed" | "new";
type RTCIceGathererState = "complete" | "gathering" | "new";
type RTCIceGatheringState = "complete" | "gathering" | "new";
type RTCIceProtocol = "tcp" | "udp";
type RTCIceRole = "controlled" | "controlling" | "unknown";
type RTCIceTcpCandidateType = "active" | "passive" | "so";
type RTCIceTransportPolicy = "all" | "relay";
type RTCIceTransportState = "checking" | "closed" | "completed" | "connected" | "disconnected" | "failed" | "new";
type RTCPeerConnectionState = "closed" | "connected" | "connecting" | "disconnected" | "failed" | "new";
type RTCPriorityType = "high" | "low" | "medium" | "very-low";
type RTCQualityLimitationReason = "bandwidth" | "cpu" | "none" | "other";
type RTCRtcpMuxPolicy = "require";
type RTCRtpTransceiverDirection = "inactive" | "recvonly" | "sendonly" | "sendrecv" | "stopped";
type RTCSctpTransportState = "closed" | "connected" | "connecting";
type RTCSdpType = "answer" | "offer" | "pranswer" | "rollback";
type RTCSignalingState = "closed" | "have-local-offer" | "have-local-pranswer" | "have-remote-offer" | "have-remote-pranswer" | "stable";
type RTCStatsIceCandidatePairState = "failed" | "frozen" | "in-progress" | "succeeded" | "waiting";
type RTCStatsType = "candidate-pair" | "certificate" | "codec" | "data-channel" | "inbound-rtp" | "local-candidate" | "media-playout" | "media-source" | "outbound-rtp" | "peer-connection" | "remote-candidate" | "remote-inbound-rtp" | "remote-outbound-rtp" | "transport";
type ReadableStreamReaderMode = "byob";
type ReadableStreamType = "bytes";
type ReadyState = "closed" | "ended" | "open";
type RecordingState = "inactive" | "paused" | "recording";
type RedEyeReduction = "always" | "controllable" | "never";
type ReferrerPolicy = "" | "no-referrer" | "no-referrer-when-downgrade" | "origin" | "origin-when-cross-origin" | "same-origin" | "strict-origin" | "strict-origin-when-cross-origin" | "unsafe-url";
type RemotePlaybackState = "connected" | "connecting" | "disconnected";
type RequestCache = "default" | "force-cache" | "no-cache" | "no-store" | "only-if-cached" | "reload";
type RequestCredentials = "include" | "omit" | "same-origin";
type RequestDestination = "" | "audio" | "audioworklet" | "document" | "embed" | "font" | "frame" | "iframe" | "image" | "manifest" | "object" | "paintworklet" | "report" | "script" | "sharedworker" | "style" | "track" | "video" | "worker" | "xslt";
type RequestMode = "cors" | "navigate" | "no-cors" | "same-origin";
type RequestPriority = "auto" | "high" | "low";
type RequestRedirect = "error" | "follow" | "manual";
type ResidentKeyRequirement = "discouraged" | "preferred" | "required";
type ResizeObserverBoxOptions = "border-box" | "content-box" | "device-pixel-content-box";
type ResizeQuality = "high" | "low" | "medium" | "pixelated";
type ResponseType = "basic" | "cors" | "default" | "error" | "opaque" | "opaqueredirect";
type SanitizerPresets = "default";
type ScrollAxis = "block" | "inline" | "x" | "y";
type ScrollBehavior = "auto" | "instant" | "smooth";
type ScrollLogicalPosition = "center" | "end" | "nearest" | "start";
type ScrollRestoration = "auto" | "manual";
type ScrollSetting = "" | "up";
type SecurityPolicyViolationEventDisposition = "enforce" | "report";
type SelectionMode = "end" | "preserve" | "select" | "start";
type ServiceWorkerState = "activated" | "activating" | "installed" | "installing" | "parsed" | "redundant";
type ServiceWorkerUpdateViaCache = "all" | "imports" | "none";
type ShadowRootMode = "closed" | "open";
type SlotAssignmentMode = "manual" | "named";
type SpeechRecognitionErrorCode = "aborted" | "audio-capture" | "language-not-supported" | "network" | "no-speech" | "not-allowed" | "phrases-not-supported" | "service-not-allowed";
type SpeechSynthesisErrorCode = "audio-busy" | "audio-hardware" | "canceled" | "interrupted" | "invalid-argument" | "language-unavailable" | "network" | "not-allowed" | "synthesis-failed" | "synthesis-unavailable" | "text-too-long" | "voice-unavailable";
type TaskPriority = "background" | "user-blocking" | "user-visible";
type TextTrackKind = "captions" | "chapters" | "descriptions" | "metadata" | "subtitles";
type TextTrackMode = "disabled" | "hidden" | "showing";
type TouchType = "direct" | "stylus";
type TransferFunction = "hlg" | "pq" | "srgb";
type UserVerificationRequirement = "discouraged" | "preferred" | "required";
type VideoColorPrimaries = "bt470bg" | "bt709" | "smpte170m";
type VideoEncoderBitrateMode = "constant" | "quantizer" | "variable";
type VideoFacingModeEnum = "environment" | "left" | "right" | "user";
type VideoMatrixCoefficients = "bt470bg" | "bt709" | "rgb" | "smpte170m";
type VideoPixelFormat = "BGRA" | "BGRX" | "I420" | "I420A" | "I422" | "I444" | "NV12" | "RGBA" | "RGBX";
type VideoTransferCharacteristics = "bt709" | "iec61966-2-1" | "smpte170m";
type WakeLockType = "screen";
type WebGLPowerPreference = "default" | "high-performance" | "low-power";
type WebTransportCongestionControl = "default" | "low-latency" | "throughput";
type WebTransportErrorSource = "session" | "stream";
type WorkerType = "classic" | "module";
type WriteCommandType = "seek" | "truncate" | "write";
type XMLHttpRequestResponseType = "" | "arraybuffer" | "blob" | "document" | "json" | "text";


/////////////////////////////
/// Window Iterable APIs
/////////////////////////////

interface AudioParam {
    /**
     * The **`setValueCurveAtTime()`** method of the AudioParam interface schedules the parameter's value to change following a curve defined by a list of values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/AudioParam/setValueCurveAtTime)
     */
    setValueCurveAtTime(values: Iterable<number>, startTime: number, duration: number): AudioParam;
}

interface AudioParamMap extends ReadonlyMap<string, AudioParam> {
}

interface BaseAudioContext {
    /**
     * The **`createIIRFilter()`** method of the BaseAudioContext interface creates an IIRFilterNode, which represents a general infinite impulse response (IIR) filter which can be configured to serve as various types of filter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createIIRFilter)
     */
    createIIRFilter(feedforward: Iterable<number>, feedback: Iterable<number>): IIRFilterNode;
    /**
     * The **`createPeriodicWave()`** method of the BaseAudioContext interface is used to create a PeriodicWave. This wave is used to define a periodic waveform that can be used to shape the output of an OscillatorNode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/BaseAudioContext/createPeriodicWave)
     */
    createPeriodicWave(real: Iterable<number>, imag: Iterable<number>, constraints?: PeriodicWaveConstraints): PeriodicWave;
}

interface CSSKeyframesRule {
    [Symbol.iterator](): ArrayIterator<CSSKeyframeRule>;
}

interface CSSNumericArray {
    [Symbol.iterator](): ArrayIterator<CSSNumericValue>;
    entries(): ArrayIterator<[number, CSSNumericValue]>;
    keys(): ArrayIterator<number>;
    values(): ArrayIterator<CSSNumericValue>;
}

interface CSSRuleList {
    [Symbol.iterator](): ArrayIterator<CSSRule>;
}

interface CSSStyleDeclaration {
    [Symbol.iterator](): ArrayIterator<string>;
}

interface CSSTransformValue {
    [Symbol.iterator](): ArrayIterator<CSSTransformComponent>;
    entries(): ArrayIterator<[number, CSSTransformComponent]>;
    keys(): ArrayIterator<number>;
    values(): ArrayIterator<CSSTransformComponent>;
}

interface CSSUnparsedValue {
    [Symbol.iterator](): ArrayIterator<CSSUnparsedSegment>;
    entries(): ArrayIterator<[number, CSSUnparsedSegment]>;
    keys(): ArrayIterator<number>;
    values(): ArrayIterator<CSSUnparsedSegment>;
}

interface Cache {
    /**
     * The **`addAll()`** method of the Cache interface takes an array of URLs, retrieves them, and adds the resulting response objects to the given cache. The request objects created during retrieval become keys to the stored response operations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Cache/addAll)
     */
    addAll(requests: Iterable<RequestInfo>): Promise<void>;
}

interface CanvasPath {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CanvasRenderingContext2D/roundRect) */
    roundRect(x: number, y: number, w: number, h: number, radii?: number | DOMPointInit | Iterable<number | DOMPointInit>): void;
}

interface CanvasPathDrawingStyles {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CanvasRenderingContext2D/setLineDash) */
    setLineDash(segments: Iterable<number>): void;
}

interface CookieStoreManager {
    /**
     * The **`subscribe()`** method of the CookieStoreManager interface subscribes a ServiceWorkerRegistration to cookie change events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CookieStoreManager/subscribe)
     */
    subscribe(subscriptions: Iterable<CookieStoreGetOptions>): Promise<void>;
    /**
     * The **`unsubscribe()`** method of the CookieStoreManager interface stops the ServiceWorkerRegistration from receiving previously subscribed events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CookieStoreManager/unsubscribe)
     */
    unsubscribe(subscriptions: Iterable<CookieStoreGetOptions>): Promise<void>;
}

interface CustomStateSet extends Set<string> {
}

interface DOMRectList {
    [Symbol.iterator](): ArrayIterator<DOMRect>;
}

interface DOMStringList {
    [Symbol.iterator](): ArrayIterator<string>;
}

interface DOMTokenList {
    [Symbol.iterator](): ArrayIterator<string>;
    entries(): ArrayIterator<[number, string]>;
    keys(): ArrayIterator<number>;
    values(): ArrayIterator<string>;
}

interface DataTransferItemList {
    [Symbol.iterator](): ArrayIterator<DataTransferItem>;
}

interface EventCounts extends ReadonlyMap<string, number> {
}

interface FileList {
    [Symbol.iterator](): ArrayIterator<File>;
}

interface FontFaceSet extends Set<FontFace> {
}

interface FormDataIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): FormDataIterator<T>;
}

interface FormData {
    [Symbol.iterator](): FormDataIterator<[string, FormDataEntryValue]>;
    /** Returns an array of key, value pairs for every entry in the list. */
    entries(): FormDataIterator<[string, FormDataEntryValue]>;
    /** Returns a list of keys in the list. */
    keys(): FormDataIterator<string>;
    /** Returns a list of values in the list. */
    values(): FormDataIterator<FormDataEntryValue>;
}

interface GPUBindingCommandsMixin {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder/setBindGroup) */
    setBindGroup(index: GPUIndex32, bindGroup: GPUBindGroup | null, dynamicOffsets?: Iterable<GPUBufferDynamicOffset>): void;
}

interface GPUCommandEncoder {
    /**
     * The **`copyBufferToTexture()`** method of the GPUCommandEncoder interface encodes a command that copies data from a GPUBuffer to a GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyBufferToTexture)
     */
    copyBufferToTexture(source: GPUTexelCopyBufferInfo, destination: GPUTexelCopyTextureInfo, copySize: Iterable<GPUIntegerCoordinate>): void;
    /**
     * The **`copyTextureToBuffer()`** method of the GPUCommandEncoder interface encodes a command that copies data from a GPUTexture to a GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyTextureToBuffer)
     */
    copyTextureToBuffer(source: GPUTexelCopyTextureInfo, destination: GPUTexelCopyBufferInfo, copySize: Iterable<GPUIntegerCoordinate>): void;
    /**
     * The **`copyTextureToTexture()`** method of the GPUCommandEncoder interface encodes a command that copies data from one GPUTexture to another.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyTextureToTexture)
     */
    copyTextureToTexture(source: GPUTexelCopyTextureInfo, destination: GPUTexelCopyTextureInfo, copySize: Iterable<GPUIntegerCoordinate>): void;
}

interface GPUQueue {
    /**
     * The **`copyExternalImageToTexture()`** method of the GPUQueue interface copies a snapshot taken from a source image, video, or canvas into a given GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/copyExternalImageToTexture)
     */
    copyExternalImageToTexture(source: GPUCopyExternalImageSourceInfo, destination: GPUCopyExternalImageDestInfo, copySize: Iterable<GPUIntegerCoordinate>): void;
    /**
     * The **`submit()`** method of the GPUQueue interface schedules the execution of command buffers represented by one or more GPUCommandBuffer objects by the GPU.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/submit)
     */
    submit(commandBuffers: Iterable<GPUCommandBuffer>): void;
    /**
     * The **`writeTexture()`** method of the GPUQueue interface writes a provided data source into a given GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/writeTexture)
     */
    writeTexture(destination: GPUTexelCopyTextureInfo, data: AllowSharedBufferSource, dataLayout: GPUTexelCopyBufferLayout, size: Iterable<GPUIntegerCoordinate>): void;
}

interface GPURenderPassEncoder {
    /**
     * The **`executeBundles()`** method of the GPURenderPassEncoder interface executes commands previously recorded into the referenced GPURenderBundles, as part of this render pass.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/executeBundles)
     */
    executeBundles(bundles: Iterable<GPURenderBundle>): void;
    /**
     * The **`setBlendConstant()`** method of the GPURenderPassEncoder interface sets the constant blend color and alpha values used with "constant" and "one-minus-constant" blend factors (as set in the descriptor of the GPUDevice.createRenderPipeline() method, in the blend property).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/setBlendConstant)
     */
    setBlendConstant(color: Iterable<number>): void;
}

interface GPUSupportedFeatures extends ReadonlySet<string> {
}

interface HTMLAllCollection {
    [Symbol.iterator](): ArrayIterator<Element>;
}

interface HTMLCollectionBase {
    [Symbol.iterator](): ArrayIterator<Element>;
}

interface HTMLCollectionOf<T extends Element> {
    [Symbol.iterator](): ArrayIterator<T>;
}

interface HTMLFormElement {
    [Symbol.iterator](): ArrayIterator<Element>;
}

interface HTMLSelectElement {
    [Symbol.iterator](): ArrayIterator<HTMLOptionElement>;
}

interface HeadersIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): HeadersIterator<T>;
}

interface Headers {
    [Symbol.iterator](): HeadersIterator<[string, string]>;
    /** Returns an iterator allowing to go through all key/value pairs contained in this object. */
    entries(): HeadersIterator<[string, string]>;
    /** Returns an iterator allowing to go through all keys of the key/value pairs contained in this object. */
    keys(): HeadersIterator<string>;
    /** Returns an iterator allowing to go through all values of the key/value pairs contained in this object. */
    values(): HeadersIterator<string>;
}

interface Highlight extends Set<AbstractRange> {
}

interface HighlightRegistry extends Map<string, Highlight> {
}

interface IDBDatabase {
    /**
     * The **`transaction`** method of the IDBDatabase interface immediately returns a transaction object (IDBTransaction) containing the IDBTransaction.objectStore method, which you can use to access your object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/transaction)
     */
    transaction(storeNames: string | Iterable<string>, mode?: IDBTransactionMode, options?: IDBTransactionOptions): IDBTransaction;
}

interface IDBObjectStore {
    /**
     * The **`createIndex()`** method of the IDBObjectStore interface creates and returns a new IDBIndex object in the connected database. It creates a new field/column defining a new data point for each database record to contain.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/createIndex)
     */
    createIndex(name: string, keyPath: string | Iterable<string>, options?: IDBIndexParameters): IDBIndex;
}

interface ImageTrackList {
    [Symbol.iterator](): ArrayIterator<ImageTrack>;
}

interface MIDIInputMap extends ReadonlyMap<string, MIDIInput> {
}

interface MIDIOutput {
    /**
     * The **`send()`** method of the MIDIOutput interface queues messages for the corresponding MIDI port. The message can be sent immediately, or with an optional timestamp to delay sending.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIOutput/send)
     */
    send(data: Iterable<number>, timestamp?: DOMHighResTimeStamp): void;
}

interface MIDIOutputMap extends ReadonlyMap<string, MIDIOutput> {
}

interface MediaKeyStatusMapIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): MediaKeyStatusMapIterator<T>;
}

interface MediaKeyStatusMap {
    [Symbol.iterator](): MediaKeyStatusMapIterator<[BufferSource, MediaKeyStatus]>;
    entries(): MediaKeyStatusMapIterator<[BufferSource, MediaKeyStatus]>;
    keys(): MediaKeyStatusMapIterator<BufferSource>;
    values(): MediaKeyStatusMapIterator<MediaKeyStatus>;
}

interface MediaList {
    [Symbol.iterator](): ArrayIterator<string>;
}

interface MessageEvent<T = any> {
    /** @deprecated */
    initMessageEvent(type: string, bubbles?: boolean, cancelable?: boolean, data?: any, origin?: string, lastEventId?: string, source?: MessageEventSource | null, ports?: Iterable<MessagePort>): void;
}

interface MimeTypeArray {
    [Symbol.iterator](): ArrayIterator<MimeType>;
}

interface NamedNodeMap {
    [Symbol.iterator](): ArrayIterator<Attr>;
}

interface Navigator {
    /**
     * The **`requestMediaKeySystemAccess()`** method of the Navigator interface returns a Promise which delivers a MediaKeySystemAccess object that can be used to access a particular media key system, which can in turn be used to create keys for decrypting a media stream.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/requestMediaKeySystemAccess)
     */
    requestMediaKeySystemAccess(keySystem: string, supportedConfigurations: Iterable<MediaKeySystemConfiguration>): Promise<MediaKeySystemAccess>;
    /**
     * The **`vibrate()`** method of the Navigator interface pulses the vibration hardware on the device, if such hardware exists. If the device doesn't support vibration, this method has no effect. If a vibration pattern is already in progress when this method is called, the previous pattern is halted and the new one begins instead.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/vibrate)
     */
    vibrate(pattern: Iterable<number>): boolean;
}

interface NodeList {
    [Symbol.iterator](): ArrayIterator<Node>;
    /** Returns an array of key, value pairs for every entry in the list. */
    entries(): ArrayIterator<[number, Node]>;
    /** Returns an list of keys in the list. */
    keys(): ArrayIterator<number>;
    /** Returns an list of values in the list. */
    values(): ArrayIterator<Node>;
}

interface NodeListOf<TNode extends Node> {
    [Symbol.iterator](): ArrayIterator<TNode>;
    /** Returns an array of key, value pairs for every entry in the list. */
    entries(): ArrayIterator<[number, TNode]>;
    /** Returns an list of keys in the list. */
    keys(): ArrayIterator<number>;
    /** Returns an list of values in the list. */
    values(): ArrayIterator<TNode>;
}

interface Plugin {
    [Symbol.iterator](): ArrayIterator<MimeType>;
}

interface PluginArray {
    [Symbol.iterator](): ArrayIterator<Plugin>;
}

interface RTCRtpTransceiver {
    /**
     * The **`setCodecPreferences()`** method of the RTCRtpTransceiver interface is used to set the codecs that the transceiver allows for decoding received data, in order of decreasing preference.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCRtpTransceiver/setCodecPreferences)
     */
    setCodecPreferences(codecs: Iterable<RTCRtpCodec>): void;
}

interface RTCStatsReport extends ReadonlyMap<string, any> {
}

interface SVGLengthList {
    [Symbol.iterator](): ArrayIterator<SVGLength>;
}

interface SVGNumberList {
    [Symbol.iterator](): ArrayIterator<SVGNumber>;
}

interface SVGPointList {
    [Symbol.iterator](): ArrayIterator<DOMPoint>;
}

interface SVGStringList {
    [Symbol.iterator](): ArrayIterator<string>;
}

interface SVGTransformList {
    [Symbol.iterator](): ArrayIterator<SVGTransform>;
}

interface SourceBufferList {
    [Symbol.iterator](): ArrayIterator<SourceBuffer>;
}

interface SpeechRecognitionResult {
    [Symbol.iterator](): ArrayIterator<SpeechRecognitionAlternative>;
}

interface SpeechRecognitionResultList {
    [Symbol.iterator](): ArrayIterator<SpeechRecognitionResult>;
}

interface StylePropertyMapReadOnlyIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): StylePropertyMapReadOnlyIterator<T>;
}

interface StylePropertyMapReadOnly {
    [Symbol.iterator](): StylePropertyMapReadOnlyIterator<[string, Iterable<CSSStyleValue>]>;
    entries(): StylePropertyMapReadOnlyIterator<[string, Iterable<CSSStyleValue>]>;
    keys(): StylePropertyMapReadOnlyIterator<string>;
    values(): StylePropertyMapReadOnlyIterator<Iterable<CSSStyleValue>>;
}

interface StyleSheetList {
    [Symbol.iterator](): ArrayIterator<CSSStyleSheet>;
}

interface SubtleCrypto {
    /**
     * The **`deriveKey()`** method of the SubtleCrypto interface can be used to derive a secret key from a master key.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/deriveKey)
     */
    deriveKey(algorithm: AlgorithmIdentifier | EcdhKeyDeriveParams | HkdfParams | Pbkdf2Params, baseKey: CryptoKey, derivedKeyType: AlgorithmIdentifier | AesDerivedKeyParams | HmacImportParams | HkdfParams | Pbkdf2Params, extractable: boolean, keyUsages: Iterable<KeyUsage>): Promise<CryptoKey>;
    /**
     * The **`generateKey()`** method of the SubtleCrypto interface is used to generate a new key (for symmetric algorithms) or key pair (for public-key algorithms).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/generateKey)
     */
    generateKey(algorithm: "Ed25519" | { name: "Ed25519" }, extractable: boolean, keyUsages: ReadonlyArray<"sign" | "verify">): Promise<CryptoKeyPair>;
    generateKey(algorithm: "X25519" | { name: "X25519" }, extractable: boolean, keyUsages: ReadonlyArray<"deriveBits" | "deriveKey">): Promise<CryptoKeyPair>;
    generateKey(algorithm: RsaHashedKeyGenParams | EcKeyGenParams, extractable: boolean, keyUsages: ReadonlyArray<KeyUsage>): Promise<CryptoKeyPair>;
    generateKey(algorithm: AesKeyGenParams | HmacKeyGenParams | Pbkdf2Params, extractable: boolean, keyUsages: ReadonlyArray<KeyUsage>): Promise<CryptoKey>;
    generateKey(algorithm: AlgorithmIdentifier, extractable: boolean, keyUsages: Iterable<KeyUsage>): Promise<CryptoKeyPair | CryptoKey>;
    /**
     * The **`importKey()`** method of the SubtleCrypto interface imports a key: that is, it takes as input a key in an external, portable format and gives you a CryptoKey object that you can use in the Web Crypto API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/importKey)
     */
    importKey(format: "jwk", keyData: JsonWebKey, algorithm: AlgorithmIdentifier | RsaHashedImportParams | EcKeyImportParams | HmacImportParams | AesKeyAlgorithm, extractable: boolean, keyUsages: ReadonlyArray<KeyUsage>): Promise<CryptoKey>;
    importKey(format: Exclude<KeyFormat, "jwk">, keyData: BufferSource, algorithm: AlgorithmIdentifier | RsaHashedImportParams | EcKeyImportParams | HmacImportParams | AesKeyAlgorithm, extractable: boolean, keyUsages: Iterable<KeyUsage>): Promise<CryptoKey>;
    /**
     * The **`unwrapKey()`** method of the SubtleCrypto interface "unwraps" a key. This means that it takes as its input a key that has been exported and then encrypted (also called "wrapped"). It decrypts the key and then imports it, returning a CryptoKey object that can be used in the Web Crypto API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/unwrapKey)
     */
    unwrapKey(format: KeyFormat, wrappedKey: BufferSource, unwrappingKey: CryptoKey, unwrapAlgorithm: AlgorithmIdentifier | RsaOaepParams | AesCtrParams | AesCbcParams | AesGcmParams, unwrappedKeyAlgorithm: AlgorithmIdentifier | RsaHashedImportParams | EcKeyImportParams | HmacImportParams | AesKeyAlgorithm, extractable: boolean, keyUsages: Iterable<KeyUsage>): Promise<CryptoKey>;
}

interface TextTrackCueList {
    [Symbol.iterator](): ArrayIterator<TextTrackCue>;
}

interface TextTrackList {
    [Symbol.iterator](): ArrayIterator<TextTrack>;
}

interface TouchList {
    [Symbol.iterator](): ArrayIterator<Touch>;
}

interface URLSearchParamsIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): URLSearchParamsIterator<T>;
}

interface URLSearchParams {
    [Symbol.iterator](): URLSearchParamsIterator<[string, string]>;
    /** Returns an array of key, value pairs for every entry in the search params. */
    entries(): URLSearchParamsIterator<[string, string]>;
    /** Returns a list of keys in the search params. */
    keys(): URLSearchParamsIterator<string>;
    /** Returns a list of values in the search params. */
    values(): URLSearchParamsIterator<string>;
}

interface ViewTransitionTypeSet extends Set<string> {
}

interface WEBGL_draw_buffers {
    /**
     * The **`WEBGL_draw_buffers.drawBuffersWEBGL()`** method is part of the WebGL API and allows you to define the draw buffers to which all fragment colors are written.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_draw_buffers/drawBuffersWEBGL)
     */
    drawBuffersWEBGL(buffers: Iterable<GLenum>): void;
}

interface WEBGL_multi_draw {
    /**
     * The **`WEBGL_multi_draw.multiDrawArraysInstancedWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawArraysInstanced() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawArraysInstancedWEBGL)
     */
    multiDrawArraysInstancedWEBGL(mode: GLenum, firstsList: Int32Array<ArrayBufferLike> | Iterable<GLint>, firstsOffset: number, countsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, countsOffset: number, instanceCountsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, instanceCountsOffset: number, drawcount: GLsizei): void;
    /**
     * The **`WEBGL_multi_draw.multiDrawArraysWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawArrays() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawArraysWEBGL)
     */
    multiDrawArraysWEBGL(mode: GLenum, firstsList: Int32Array<ArrayBufferLike> | Iterable<GLint>, firstsOffset: number, countsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, countsOffset: number, drawcount: GLsizei): void;
    /**
     * The **`WEBGL_multi_draw.multiDrawElementsInstancedWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawElementsInstanced() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawElementsInstancedWEBGL)
     */
    multiDrawElementsInstancedWEBGL(mode: GLenum, countsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, countsOffset: number, type: GLenum, offsetsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, offsetsOffset: number, instanceCountsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, instanceCountsOffset: number, drawcount: GLsizei): void;
    /**
     * The **`WEBGL_multi_draw.multiDrawElementsWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawElements() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawElementsWEBGL)
     */
    multiDrawElementsWEBGL(mode: GLenum, countsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, countsOffset: number, type: GLenum, offsetsList: Int32Array<ArrayBufferLike> | Iterable<GLsizei>, offsetsOffset: number, drawcount: GLsizei): void;
}

interface WGSLLanguageFeatures extends ReadonlySet<string> {
}

interface WebGL2RenderingContextBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferfv(buffer: GLenum, drawbuffer: GLint, values: Iterable<GLfloat>, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferiv(buffer: GLenum, drawbuffer: GLint, values: Iterable<GLint>, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferuiv(buffer: GLenum, drawbuffer: GLint, values: Iterable<GLuint>, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/drawBuffers) */
    drawBuffers(buffers: Iterable<GLenum>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getActiveUniforms) */
    getActiveUniforms(program: WebGLProgram, uniformIndices: Iterable<GLuint>, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getUniformIndices) */
    getUniformIndices(program: WebGLProgram, uniformNames: Iterable<string>): GLuint[] | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/invalidateFramebuffer) */
    invalidateFramebuffer(target: GLenum, attachments: Iterable<GLenum>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/invalidateSubFramebuffer) */
    invalidateSubFramebuffer(target: GLenum, attachments: Iterable<GLenum>, x: GLint, y: GLint, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/transformFeedbackVaryings) */
    transformFeedbackVaryings(program: WebGLProgram, varyings: Iterable<string>, bufferMode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform1uiv(location: WebGLUniformLocation | null, data: Iterable<GLuint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform2uiv(location: WebGLUniformLocation | null, data: Iterable<GLuint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform3uiv(location: WebGLUniformLocation | null, data: Iterable<GLuint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform4uiv(location: WebGLUniformLocation | null, data: Iterable<GLuint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix2x3fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix2x4fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix3x2fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix3x4fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix4x2fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix4x3fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribI) */
    vertexAttribI4iv(index: GLuint, values: Iterable<GLint>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribI) */
    vertexAttribI4uiv(index: GLuint, values: Iterable<GLuint>): void;
}

interface WebGL2RenderingContextOverloads {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1fv(location: WebGLUniformLocation | null, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1iv(location: WebGLUniformLocation | null, data: Iterable<GLint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2fv(location: WebGLUniformLocation | null, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2iv(location: WebGLUniformLocation | null, data: Iterable<GLint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3fv(location: WebGLUniformLocation | null, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3iv(location: WebGLUniformLocation | null, data: Iterable<GLint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4fv(location: WebGLUniformLocation | null, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4iv(location: WebGLUniformLocation | null, data: Iterable<GLint>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix2fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix3fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix4fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Iterable<GLfloat>, srcOffset?: number, srcLength?: GLuint): void;
}

interface WebGLRenderingContextBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib1fv(index: GLuint, values: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib2fv(index: GLuint, values: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib3fv(index: GLuint, values: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/vertexAttrib) */
    vertexAttrib4fv(index: GLuint, values: Iterable<GLfloat>): void;
}

interface WebGLRenderingContextOverloads {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1fv(location: WebGLUniformLocation | null, v: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1iv(location: WebGLUniformLocation | null, v: Iterable<GLint>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2fv(location: WebGLUniformLocation | null, v: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2iv(location: WebGLUniformLocation | null, v: Iterable<GLint>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3fv(location: WebGLUniformLocation | null, v: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3iv(location: WebGLUniformLocation | null, v: Iterable<GLint>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4fv(location: WebGLUniformLocation | null, v: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4iv(location: WebGLUniformLocation | null, v: Iterable<GLint>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix2fv(location: WebGLUniformLocation | null, transpose: GLboolean, value: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix3fv(location: WebGLUniformLocation | null, transpose: GLboolean, value: Iterable<GLfloat>): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix4fv(location: WebGLUniformLocation | null, transpose: GLboolean, value: Iterable<GLfloat>): void;
}


/////////////////////////////
/// Window Async Iterable APIs
/////////////////////////////

interface FileSystemDirectoryHandleAsyncIterator<T> extends AsyncIteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.asyncIterator](): FileSystemDirectoryHandleAsyncIterator<T>;
}

interface FileSystemDirectoryHandle {
    [Symbol.asyncIterator](): FileSystemDirectoryHandleAsyncIterator<[string, FileSystemDirectoryHandle | FileSystemFileHandle]>;
    entries(): FileSystemDirectoryHandleAsyncIterator<[string, FileSystemDirectoryHandle | FileSystemFileHandle]>;
    keys(): FileSystemDirectoryHandleAsyncIterator<string>;
    values(): FileSystemDirectoryHandleAsyncIterator<FileSystemDirectoryHandle | FileSystemFileHandle>;
}

interface ReadableStreamAsyncIterator<T> extends AsyncIteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.asyncIterator](): ReadableStreamAsyncIterator<T>;
}

interface ReadableStream<R = any> {
    [Symbol.asyncIterator](options?: ReadableStreamIteratorOptions): ReadableStreamAsyncIterator<R>;
    values(options?: ReadableStreamIteratorOptions): ReadableStreamAsyncIterator<R>;
}

//========== lib.dom.iterable.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


// This file's contents are now included in the main types file.
// The file has been left for backward compatibility.

//========== lib.dom.asynciterable.d.ts ==========
/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABILITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */


// This file's contents are now included in the main types file.
// The file has been left for backward compatibility.
