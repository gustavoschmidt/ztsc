
declare var HTMLFormElement: {
    prototype: HTMLFormElement;
    new(): HTMLFormElement;
};

/** @deprecated */
interface HTMLFrameElement extends HTMLElement {
    /** @deprecated */
    readonly contentDocument: Document | null;
    /** @deprecated */
    readonly contentWindow: WindowProxy | null;
    /** @deprecated */
    frameBorder: string;
    /** @deprecated */
    longDesc: string;
    /** @deprecated */
    marginHeight: string;
    /** @deprecated */
    marginWidth: string;
    /** @deprecated */
    name: string;
    /** @deprecated */
    noResize: boolean;
    /** @deprecated */
    scrolling: string;
    /** @deprecated */
    src: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFrameElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFrameElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var HTMLFrameElement: {
    prototype: HTMLFrameElement;
    new(): HTMLFrameElement;
};

interface HTMLFrameSetElementEventMap extends HTMLElementEventMap, WindowEventHandlersEventMap {
}

/**
 * The **`HTMLFrameSetElement`** interface provides special properties (beyond those of the regular HTMLElement interface they also inherit) for manipulating <frameset> elements.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFrameSetElement)
 */
interface HTMLFrameSetElement extends HTMLElement, WindowEventHandlers {
    /** @deprecated */
    cols: string;
    /** @deprecated */
    rows: string;
    addEventListener<K extends keyof HTMLFrameSetElementEventMap>(type: K, listener: (this: HTMLFrameSetElement, ev: HTMLFrameSetElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLFrameSetElementEventMap>(type: K, listener: (this: HTMLFrameSetElement, ev: HTMLFrameSetElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var HTMLFrameSetElement: {
    prototype: HTMLFrameSetElement;
    new(): HTMLFrameSetElement;
};

/**
 * The **`HTMLHRElement`** interface provides special properties (beyond those of the HTMLElement interface it also has available to it by inheritance) for manipulating <hr> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLHRElement)
 */
interface HTMLHRElement extends HTMLElement {
    /** @deprecated */
    align: string;
    /** @deprecated */
    color: string;
    /** @deprecated */
    noShade: boolean;
    /** @deprecated */
    size: string;
    /** @deprecated */
    width: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHRElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHRElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLHRElement: {
    prototype: HTMLHRElement;
    new(): HTMLHRElement;
};

/**
 * The **`HTMLHeadElement`** interface contains the descriptive information, or metadata, for a document. This object inherits all of the properties and methods described in the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLHeadElement)
 */
interface HTMLHeadElement extends HTMLElement {
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHeadElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHeadElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLHeadElement: {
    prototype: HTMLHeadElement;
    new(): HTMLHeadElement;
};

/**
 * The **`HTMLHeadingElement`** interface represents the different heading elements, <h1> through <h6>. It inherits methods and properties from the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLHeadingElement)
 */
interface HTMLHeadingElement extends HTMLElement {
    /** @deprecated */
    align: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHeadingElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHeadingElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLHeadingElement: {
    prototype: HTMLHeadingElement;
    new(): HTMLHeadingElement;
};

/**
 * The **`HTMLHtmlElement`** interface serves as the root node for a given HTML document. This object inherits the properties and methods described in the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLHtmlElement)
 */
interface HTMLHtmlElement extends HTMLElement {
    /**
     * Returns **`version`** information about the document type definition (DTD) of a document. While this property is recognized by Mozilla, the return value for this property is always an empty string.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLHtmlElement/version)
     */
    version: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHtmlElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLHtmlElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLHtmlElement: {
    prototype: HTMLHtmlElement;
    new(): HTMLHtmlElement;
};

interface HTMLHyperlinkElementUtils {
    /**
     * Returns the hyperlink's URL's fragment (includes leading "#" if non-empty).
     *
     * Can be set, to change the URL's fragment (ignores leading "#").
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/hash)
     */
    hash: string;
    /**
     * Returns the hyperlink's URL's host and port (if different from the default port for the scheme).
     *
     * Can be set, to change the URL's host and port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/host)
     */
    host: string;
    /**
     * Returns the hyperlink's URL's host.
     *
     * Can be set, to change the URL's host.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/hostname)
     */
    hostname: string;
    /**
     * Returns the hyperlink's URL.
     *
     * Can be set, to change the URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/href)
     */
    href: string;
    toString(): string;
    /**
     * Returns the hyperlink's URL's origin.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/origin)
     */
    readonly origin: string;
    /**
     * Returns the hyperlink's URL's password.
     *
     * Can be set, to change the URL's password.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/password)
     */
    password: string;
    /**
     * Returns the hyperlink's URL's path.
     *
     * Can be set, to change the URL's path.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/pathname)
     */
    pathname: string;
    /**
     * Returns the hyperlink's URL's port.
     *
     * Can be set, to change the URL's port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/port)
     */
    port: string;
    /**
     * Returns the hyperlink's URL's scheme.
     *
     * Can be set, to change the URL's scheme.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/protocol)
     */
    protocol: string;
    /**
     * Returns the hyperlink's URL's query (includes leading "?" if non-empty).
     *
     * Can be set, to change the URL's query (ignores leading "?").
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/search)
     */
    search: string;
    /**
     * Returns the hyperlink's URL's username.
     *
     * Can be set, to change the URL's username.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/username)
     */
    username: string;
}

/**
 * The **`HTMLIFrameElement`** interface provides special properties and methods (beyond those of the HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of inline frame elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement)
 */
interface HTMLIFrameElement extends HTMLElement {
    /** @deprecated */
    align: string;
    /**
     * The **`allow`** property of the HTMLIFrameElement interface indicates the Permissions Policy specified for this <iframe> element. The policy defines what features are available to the <iframe> element (for example, access to the microphone, camera, battery, web-share, etc.) based on the origin of the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/allow)
     */
    allow: string;
    /**
     * The **`allowFullscreen`** property of the HTMLIFrameElement interface is a boolean value that reflects the allowfullscreen attribute of the <iframe> element, indicating whether to allow the iframe's contents to use requestFullscreen().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/allowFullscreen)
     */
    allowFullscreen: boolean;
    /**
     * If the iframe and the iframe's parent document are Same Origin, returns a Document (that is, the active document in the inline frame's nested browsing context), else returns null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/contentDocument)
     */
    readonly contentDocument: Document | null;
    /**
     * The **`contentWindow`** property returns the Window object of an HTMLIFrameElement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/contentWindow)
     */
    readonly contentWindow: WindowProxy | null;
    /** @deprecated */
    frameBorder: string;
    /**
     * The **`height`** property of the HTMLIFrameElement interface returns a string that reflects the height attribute of the <iframe> element, indicating the height of the frame in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/height)
     */
    height: string;
    /**
     * The **`loading`** property of the HTMLIFrameElement interface is a string that provides a hint to the user agent indicating whether the iframe should be loaded immediately on page load, or only when it is needed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/loading)
     */
    loading: "eager" | "lazy";
    /** @deprecated */
    longDesc: string;
    /** @deprecated */
    marginHeight: string;
    /** @deprecated */
    marginWidth: string;
    /**
     * The **`name`** property of the HTMLIFrameElement interface is a string value that reflects the name attribute of the <iframe> element, indicating the specific name of the <iframe> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/name)
     */
    name: string;
    /**
     * The **`HTMLIFrameElement.referrerPolicy`** property reflects the HTML referrerpolicy attribute of the <iframe> element defining which referrer is sent when fetching the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/referrerPolicy)
     */
    referrerPolicy: ReferrerPolicy;
    /**
     * The read-only **`sandbox`** property of the HTMLIFrameElement returns a live DOMTokenList object indicating extra restrictions on the behavior of the nested content. It reflects the <iframe> element's sandbox content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/sandbox)
     */
    get sandbox(): DOMTokenList;
    set sandbox(value: string);
    /** @deprecated */
    scrolling: string;
    /**
     * The **`HTMLIFrameElement.src`** A string that reflects the src HTML attribute, containing the address of the content to be embedded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/src)
     */
    src: string;
    /**
     * The **`srcdoc`** property of the HTMLIFrameElement interface gets or sets the inline HTML markup of the frame's document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/srcdoc)
     */
    srcdoc: string;
    /**
     * The **`width`** property of the HTMLIFrameElement interface returns a string that reflects the width attribute of the <iframe> element, indicating the width of the frame in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/width)
     */
    width: string;
    /**
     * The **`getSVGDocument()`** method of the HTMLIFrameElement interface returns the Document object of the embedded SVG.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLIFrameElement/getSVGDocument)
     */
    getSVGDocument(): Document | null;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLIFrameElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLIFrameElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLIFrameElement: {
    prototype: HTMLIFrameElement;
    new(): HTMLIFrameElement;
};

/**
 * The **`HTMLImageElement`** interface represents an HTML <img> element, providing the properties and methods used to manipulate image elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement)
 */
interface HTMLImageElement extends HTMLElement {
    /**
     * The deprecated **`align`** property of the HTMLImageElement interface is a string which indicates how to position the image relative to its container. It reflects the <img> element's align content attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/align)
     */
    align: string;
    /**
     * The **`alt`** property of the HTMLImageElement interface provides fallback (alternate) text to display when the image specified by the <img> element is not displayed, whether because of an error, because the user has disabled the loading of images, or because the image hasn't finished loading yet. It reflects the <img> element's alt content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/alt)
     */
    alt: string;
    /**
     * The deprecated **`border`** property of the HTMLImageElement interface specifies the number of pixels thick the border surrounding the image should be. A value of 0, the default, indicates that no border should be drawn. It reflects the <img> element's border content attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/border)
     */
    border: string;
    /**
     * The **`complete`** read-only property of the HTMLImageElement interface is a Boolean value indicating whether or not the image has completely loaded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/complete)
     */
    readonly complete: boolean;
    /**
     * The **`crossOrigin`** property of the HTMLImageElement interface is a string which specifies the Cross-Origin Resource Sharing (CORS) setting to use when retrieving the image. It reflects the <img> element's crossorigin content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/crossOrigin)
     */
    crossOrigin: string | null;
    /**
     * The **`currentSrc`** read-only property of the HTMLImageElement interface indicates the URL of the image selected by the browser to load.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/currentSrc)
     */
    readonly currentSrc: string;
    /**
     * The **`decoding`** property of the HTMLImageElement interface provides a hint to the browser as to how it should decode the image. More specifically, whether it should wait for the image to be decoded before presenting other content updates or not. It reflects the <img> element's decoding content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/decoding)
     */
    decoding: "async" | "sync" | "auto";
    /**
     * The **`fetchPriority`** property of the HTMLImageElement interface represents a hint to the browser indicating how it should prioritize fetching a particular image relative to other images. It reflects the <img> element's fetchpriority content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/fetchPriority)
     */
    fetchPriority: "high" | "low" | "auto";
    /**
     * The **`height`** property of the HTMLImageElement interface indicates the height at which the image is drawn, in CSS pixels, if the image is being drawn or rendered to any visual medium such as a screen or printer. Otherwise, it's the natural, pixel density-corrected height of the image.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/height)
     */
    height: number;
    /**
     * The deprecated **`hspace`** property of the HTMLImageElement interface specifies the number of pixels of empty space to leave empty on the left and right sides of the <img> element when laying out the page. It reflects the <img> element's hspace content attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/hspace)
     */
    hspace: number;
    /**
     * The **`isMap`** property of the HTMLImageElement interface indicates that the image is part of a server-side map. If so, the coordinates where the user clicked on the image are sent to the server. It reflects the <img> element's ismap content attribute. This attribute is allowed only if the <img> element is a descendant of an <a> element with a valid href attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/isMap)
     */
    isMap: boolean;
    /**
     * The **`loading`** property of the HTMLImageElement interface provides a hint to the user agent on how to handle the loading of the image which is currently outside the window's visual viewport. This helps to optimize the loading of the document's contents by postponing loading the image until it's expected to be needed, rather than immediately during the initial page load. It reflects the <img> element's loading content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/loading)
     */
    loading: "eager" | "lazy";
    /**
     * The deprecated **`longDesc`** property of the HTMLImageElement interface specifies the URL of a text or HTML file which contains a long-form description of the image. This can be used to provide optional added details beyond the short description provided in the title attribute. It reflects the <img> element's longdesc content attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/longDesc)
     */
    longDesc: string;
    /** @deprecated */
    lowsrc: string;
    /**
     * The deprecated **`name`** property of the HTMLImageElement interface specifies a name for the element. It reflects the <img> element's name content attribute. It has been replaced by the id property available on all elements, and is kept only for compatibility reasons.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/name)
     */
    name: string;
    /**
     * The read-only **`naturalHeight`** property of the HTMLImageElement interface returns the intrinsic (natural), density-corrected height of the image in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/naturalHeight)
     */
    readonly naturalHeight: number;
    /**
     * The read-only **`naturalWidth`** property of the HTMLImageElement interface returns the intrinsic (natural), density-corrected width of the image in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/naturalWidth)
     */
    readonly naturalWidth: number;
    /**
     * The **`referrerPolicy`** property of the HTMLImageElement interface defining which referrer is sent when fetching the resource. It reflects the <img> element's referrerpolicy content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/referrerPolicy)
     */
    referrerPolicy: string;
    /**
     * The **`sizes`** property of the HTMLImageElement interface allows you to specify the layout width of the image for each of a list of media queries. This provides the ability to automatically select among different images—even images of different orientations or aspect ratios—as the document state changes to match different media conditions. It reflects the <img> element's sizes content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/sizes)
     */
    sizes: string;
    /**
     * The **`src`** property of the HTMLImageElement interface specifies the image to display in the <img> element. It reflects the <img> element's src content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/src)
     */
    src: string;
    /**
     * The **`srcset`** property of the HTMLImageElement interface identifies one or more image candidate strings, separated using commas (,), each specifying image resources to use under given circumstances. Each image candidate string contains an image URL and an optional width or pixel density descriptor that indicates the conditions under which that candidate should be used instead of the image specified by the src property. It reflects the <img> element's srcset content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/srcset)
     */
    srcset: string;
    /**
     * The **`useMap`** property of the HTMLImageElement interface providing the name of the client-side image map to apply to the image. It reflects the <img> element's usemap content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/useMap)
     */
    useMap: string;
    /**
     * The deprecated **`vspace`** property of the HTMLImageElement interface specifies the number of pixels of empty space to leave empty on the top and bottom sides of the <img> element when laying out the page. It reflects the <img> element's vspace content attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/vspace)
     */
    vspace: number;
    /**
     * The **`width`** property of the HTMLImageElement interface indicates the width at which the image is drawn, in CSS pixels, if the image is being drawn or rendered to any visual medium such as a screen or printer. Otherwise, it's the natural, pixel density-corrected width of the image.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/width)
     */
    width: number;
    /**
     * The read-only **`x`** property of the HTMLImageElement interface indicates the x-coordinate of the <img> element's left border edge relative to the root element's origin.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/x)
     */
    readonly x: number;
    /**
     * The read-onl**`y`** y property of the HTMLImageElement interface indicates the y-coordinate of the <img> element's top border edge relative to the root element's origin.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/y)
     */
    readonly y: number;
    /**
     * The **`decode()`** method of the HTMLImageElement interface returns a Promise that resolves once the image is decoded and is safe to be appended to the DOM.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLImageElement/decode)
     */
    decode(): Promise<void>;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLImageElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLImageElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLImageElement: {
    prototype: HTMLImageElement;
    new(): HTMLImageElement;
};

/**
 * The **`HTMLInputElement`** interface provides special properties and methods for manipulating the options, layout, and presentation of <input> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement)
 */
interface HTMLInputElement extends HTMLElement, PopoverTargetAttributes {
    /**
     * The **`accept`** property of the HTMLInputElement interface reflects the <input> element's accept attribute, generally a comma-separated list of unique file type specifiers providing a hint for the expected file type for an <input> of type file. If the attribute is not explicitly set, the accept property is an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/accept)
     */
    accept: string;
    /** @deprecated */
    align: string;
    /**
     * The **`alt`** property of the HTMLInputElement interface defines the textual label for the button for users and user agents who cannot use the image. It reflects the <input> element's alt attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/alt)
     */
    alt: string;
    /**
     * The **`autocomplete`** property of the HTMLInputElement interface indicates whether the value of the control can be automatically completed by the browser. It reflects the <input> element's autocomplete attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/autocomplete)
     */
    autocomplete: AutoFill;
    /**
     * The **`capture`** property of the HTMLInputElement interface reflects the <input> element's capture attribute. Only relevant to the <input> of type file, the property and attribute specify whether, a new file should be captured from a user-facing (user) or outward facing (environment) camera or microphone. The type of file is defined the accept attribute. If the attribute is not explicitly set, the capture property is an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/capture)
     */
    capture: string;
    /**
     * The **`checked`** property of the HTMLInputElement interface specifies the current checkedness of the element; that is, whether the form control is checked or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/checked)
     */
    checked: boolean;
    /**
     * The **`defaultChecked`** property of the HTMLInputElement interface specifies the default checkedness state of the element. This property reflects the <input> element's checked attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/defaultChecked)
     */
    defaultChecked: boolean;
    /**
     * The **`defaultValue`** property of the HTMLInputElement interface indicates the original (or default) value of the <input> element. It reflects the element's value attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/defaultValue)
     */
    defaultValue: string;
    /**
     * The **`dirName`** property of the HTMLInputElement interface is the directionality of the element and enables the submission of that value. It reflects the value of the <input> element's dirName attribute. This property can be retrieved or set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/dirName)
     */
    dirName: string;
    /**
     * The **`HTMLInputElement.disabled`** property is a boolean value that reflects the disabled HTML attribute, which indicates whether the control is disabled. If it is disabled, it does not accept clicks. A disabled element is unusable and un-clickable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`HTMLInputElement.files`** property allows you to access the FileList selected with the <input type="file"> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/files)
     */
    files: FileList | null;
    /**
     * The **`form`** read-only property of the HTMLInputElement interface returns an HTMLFormElement object that owns this <input>, or null if this input is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`formAction`** property of the HTMLInputElement interface is the URL of the program that is executed on the server when the form that owns this control is submitted. It reflects the value of the <input>'s formaction attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/formAction)
     */
    formAction: string;
    /**
     * The **`formEnctype`** property of the HTMLInputElement interface is the MIME type of the content sent to the server when the <input> with the formEnctype is the method of form submission. It reflects the value of the <input>'s formenctype attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/formEnctype)
     */
    formEnctype: string;
    /**
     * The **`formMethod`** property of the HTMLInputElement interface is the HTTP method used to submit the <form> if the <input> element is the control that submits the form. It reflects the value of the <input>'s formmethod attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/formMethod)
     */
    formMethod: string;
    /**
     * The **`formNoValidate`** property of the HTMLInputElement interface is a boolean value indicating if the <form> will bypass constraint validation when submitted via the <input>. It reflects the <input> element's formnovalidate attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/formNoValidate)
     */
    formNoValidate: boolean;
    /**
     * The **`formTarget`** property of the HTMLInputElement interface is the tab, window, or iframe where the response of the submitted <form> is to be displayed. It reflects the value of the <input> element's formtarget attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/formTarget)
     */
    formTarget: string;
    /**
     * The **`height`** property of the HTMLInputElement interface specifies the height of a control. It reflects the <input> element's height attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/height)
     */
    height: number;
    /**
     * The **`indeterminate`** property of the HTMLInputElement interface returns a boolean value that indicates whether the checkbox is in the indeterminate state. For example, a "select all/deselect all" checkbox may be in the indeterminate state when some but not all of its sub-controls are checked. The indeterminate state can only be set via JavaScript and is only relevant to checkbox controls.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/indeterminate)
     */
    indeterminate: boolean;
    /**
     * The **`HTMLInputElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <input> element, if the element is not hidden. If the element has the type hidden, the property returns null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement> | null;
    /**
     * The **`list`** read-only property of the HTMLInputElement interface returns the HTMLDataListElement pointed to by the list attribute of the element, or null if the list attribute is not defined or the list attribute's value is not associated with any <datalist> in the same tree.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/list)
     */
    readonly list: HTMLDataListElement | null;
    /**
     * The **`max`** property of the HTMLInputElement interface reflects the <input> element's max attribute, which generally defines the maximum valid value for a numeric or date-time input. If the attribute is not explicitly set, the max property is an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/max)
     */
    max: string;
    /**
     * The **`maxLength`** property of the HTMLInputElement interface indicates the maximum number of characters (in UTF-16 code units) allowed to be entered for the value of the <input> element, and the maximum number of characters allowed for the value to be valid. It reflects the element's maxlength attribute. -1 means there is no limit on the length of the value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/maxLength)
     */
    maxLength: number;
    /**
     * The **`min`** property of the HTMLInputElement interface reflects the <input> element's min attribute, which generally defines the minimum valid value for a numeric or date-time input. If the attribute is not explicitly set, the min property is an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/min)
     */
    min: string;
    /**
     * The **`minLength`** property of the HTMLInputElement interface indicates the minimum number of characters (in UTF-16 code units) required for the value of the <input> element to be valid. It reflects the element's minlength attribute. -1 means there is no minimum length requirement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/minLength)
     */
    minLength: number;
    /**
     * The **`HTMLInputElement.multiple`** property indicates if an input can have more than one value. Firefox currently only supports multiple for <input type="file">.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/multiple)
     */
    multiple: boolean;
    /**
     * The **`name`** property of the HTMLInputElement interface indicates the name of the <input> element. It reflects the element's name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/name)
     */
    name: string;
    /**
     * The **`pattern`** property of the HTMLInputElement interface represents a regular expression a non-null <input> value should match. It reflects the <input> element's pattern attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/pattern)
     */
    pattern: string;
    /**
     * The **`placeholder`** property of the HTMLInputElement interface represents a hint to the user of what can be entered in the control. It reflects the <input> element's placeholder attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/placeholder)
     */
    placeholder: string;
    /**
     * The **`readOnly`** property of the HTMLInputElement interface indicates that the user cannot modify the value of the <input>. It reflects the <input> element's readonly boolean attribute; returning true if the attribute is present and false when omitted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/readOnly)
     */
    readOnly: boolean;
    /**
     * The **`required`** property of the HTMLInputElement interface specifies that the user must fill in a value before submitting a form. It reflects the <input> element's required attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/required)
     */
    required: boolean;
    /**
     * The **`selectionDirection`** property of the HTMLInputElement interface is a string that indicates the direction in which the user is selecting the text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/selectionDirection)
     */
    selectionDirection: SelectionDirection | null;
    /**
     * The **`selectionEnd`** property of the HTMLInputElement interface is a number that represents the end index of the selected text. That is, it represents the index of the character immediately following the selection. Likewise, when there is no selection, this returns the offset of the character immediately following the current text input cursor position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/selectionEnd)
     */
    selectionEnd: number | null;
    /**
     * The **`selectionStart`** property of the HTMLInputElement interface is a number that represents the beginning index of the selected text. When nothing is selected, then returns the position of the text input cursor (caret) inside of the <input> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/selectionStart)
     */
    selectionStart: number | null;
    /**
     * The **`size`** property of the HTMLInputElement interface defines the number of visible characters displayed. It reflects the <input> element's size attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/size)
     */
    size: number;
    /**
     * The **`src`** property of the HTMLInputElement interface specifies the source of an image to display as the graphical submit button. It reflects the <input> element's src attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/src)
     */
    src: string;
    /**
     * The **`step`** property of the HTMLInputElement interface indicates the step by which numeric or date-time <input> elements can change. It reflects the element's step attribute. Valid values include the string "any" or a string containing a positive floating point number. If the attribute is not explicitly set, the step property is an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/step)
     */
    step: string;
    /**
     * The **`type`** property of the HTMLInputElement interface indicates the kind of data allowed in the <input> element, for example a number, a date, or an email. Browsers will select the appropriate widget and behavior to help users to enter a valid value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/type)
     */
    type: string;
    /** @deprecated */
    useMap: string;
    /**
     * The **`validationMessage`** read-only property of the HTMLInputElement interface returns a string representing a localized message that describes the validation constraints that the <input> control does not satisfy (if any).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLInputElement interface returns a ValidityState object that represents the validity states this element is in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`value`** property of the HTMLInputElement interface represents the current value of the <input> element as a string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/value)
     */
    value: string;
    /**
     * The **`valueAsDate`** property of the HTMLInputElement interface represents the current value of the <input> element as a Date, or null if conversion is not possible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/valueAsDate)
     */
    valueAsDate: Date | null;
    /**
     * The **`valueAsNumber`** property of the HTMLInputElement interface represents the current value of the <input> element as a number or NaN if converting to a numeric value is not possible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/valueAsNumber)
     */
    valueAsNumber: number;
    /**
     * The read-only **`webkitEntries`** property of the HTMLInputElement interface contains an array of file system entries (as objects based on FileSystemEntry) representing files and/or directories selected by the user using an <input> element of type file, but only if that selection was made using drag-and-drop: selecting a file in the dialog will leave the property empty.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/webkitEntries)
     */
    readonly webkitEntries: ReadonlyArray<FileSystemEntry>;
    /**
     * The **`webkitdirectory`** property of the HTMLInputElement interface reflects the webkitdirectory HTML attribute, which indicates that <input type="file"> elements can only select directories instead of files.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/webkitdirectory)
     */
    webkitdirectory: boolean;
    /**
     * The **`width`** property of the HTMLInputElement interface specifies the width of a control. It reflects the <input> element's width attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/width)
     */
    width: number;
    /**
     * The **`willValidate`** read-only property of the HTMLInputElement interface indicates whether the <input> element is a candidate for constraint validation. It is false if any conditions bar it from constraint validation, including:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`checkValidity()`** method of the HTMLInputElement interface returns a boolean value which indicates if the element meets any constraint validation rules applied to it. If false, the method also fires an invalid event on the element. Because there's no default browser behavior for checkValidity(), canceling this invalid event has no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the HTMLInputElement interface performs the same validity checking steps as the checkValidity() method. In addition, if the invalid event is not canceled, the browser displays the problem to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`HTMLInputElement.select()`** method selects all the text in a <textarea> element or in an <input> element that includes a text field.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/select)
     */
    select(): void;
    /**
     * The **`HTMLInputElement.setCustomValidity()`** method sets a custom validity message for the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    /**
     * The **`HTMLInputElement.setRangeText()`** method replaces a range of text in an <input> or <textarea> element with a new string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/setRangeText)
     */
    setRangeText(replacement: string): void;
    setRangeText(replacement: string, start: number, end: number, selectionMode?: SelectionMode): void;
    /**
     * The **`HTMLInputElement.setSelectionRange()`** method sets the start and end positions of the current text selection in an <input> or <textarea> element. This updates the selection state immediately, though the visual highlight only appears when the element is focused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/setSelectionRange)
     */
    setSelectionRange(start: number | null, end: number | null, direction?: SelectionDirection): void;
    /**
     * The **`HTMLInputElement.showPicker()`** method displays the browser picker for an input element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/showPicker)
     */
    showPicker(): void;
    /**
     * The **`HTMLInputElement.stepDown()`** method decrements the value of a numeric type of <input> element by the value of the step attribute or up to n multiples of the step attribute if a number is passed as the parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/stepDown)
     */
    stepDown(n?: number): void;
    /**
     * The **`HTMLInputElement.stepUp()`** method increments the value of a numeric type of <input> element by the value of the step attribute, or the default step value if the step attribute is not explicitly set. The method, when invoked, increments the value by (step * n), where n defaults to 1 if not specified, and step defaults to the default value for step if not specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/stepUp)
     */
    stepUp(n?: number): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLInputElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLInputElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLInputElement: {
    prototype: HTMLInputElement;
    new(): HTMLInputElement;
};

/**
 * The **`HTMLLIElement`** interface exposes specific properties and methods (beyond those defined by regular HTMLElement interface it also has available to it by inheritance) for manipulating list elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLIElement)
 */
interface HTMLLIElement extends HTMLElement {
    /** @deprecated */
    type: string;
    /**
     * The **`value`** property of the HTMLLIElement interface indicates the ordinal position of the list element inside a given <ol>. It can be smaller than 0. If the <li> element is not a child of an <ol> element, the property has no meaning.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLIElement/value)
     */
    value: number;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLIElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLIElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLLIElement: {
    prototype: HTMLLIElement;
    new(): HTMLLIElement;
};

/**
 * The **`HTMLLabelElement`** interface gives access to properties specific to <label> elements. It inherits methods and properties from the base HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLabelElement)
 */
interface HTMLLabelElement extends HTMLElement {
    /**
     * The read-only **`HTMLLabelElement.control`** property returns a reference to the control (in the form of an object of type HTMLElement or one of its derivatives) with which the <label> element is associated, or null if the label isn't associated with a control.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLabelElement/control)
     */
    readonly control: HTMLElement | null;
    /**
     * The **`form`** read-only property of the HTMLLabelElement interface returns an HTMLFormElement object that owns the control associated with this <label>, or null if this label is not associated with a labelable form-associated element (<button>, <input>, <output>, <select>, <textarea>, or form-associated custom elements) that is owned by a form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLabelElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`HTMLLabelElement.htmlFor`** property reflects the value of the for content property. That means that this script-accessible property is used to set and read the value of the content property for, which is the ID of the label's associated control element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLabelElement/htmlFor)
     */
    htmlFor: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLabelElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLabelElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLLabelElement: {
    prototype: HTMLLabelElement;
    new(): HTMLLabelElement;
};

/**
 * The **`HTMLLegendElement`** is an interface allowing to access properties of the <legend> elements. It inherits properties and methods from the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLegendElement)
 */
interface HTMLLegendElement extends HTMLElement {
    /** @deprecated */
    align: string;
    /**
     * The **`form`** read-only property of the HTMLLegendElement interface returns an HTMLFormElement object that owns the HTMLFieldSetElement associated with this <legend>, or null if this legend is not associated with a <fieldset> owned by a form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLegendElement/form)
     */
    readonly form: HTMLFormElement | null;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLegendElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLegendElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLLegendElement: {
    prototype: HTMLLegendElement;
    new(): HTMLLegendElement;
};

/**
 * The **`HTMLLinkElement`** interface represents reference information for external resources and the relationship of those resources to a document and vice versa (corresponds to <link> element; not to be confused with <a>, which is represented by HTMLAnchorElement). This object inherits all of the properties and methods of the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement)
 */
interface HTMLLinkElement extends HTMLElement, LinkStyle {
    /**
     * The **`as`** property of the HTMLLinkElement interface returns a string representing the type of content to be preloaded by a link element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/as)
     */
    as: string;
    /**
     * The read-only **`blocking`** property of the HTMLLinkElement returns a live DOMTokenList object containing the operations that should be blocked on the fetching of an external resource. It reflects the <link> element's blocking content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/blocking)
     */
    get blocking(): DOMTokenList;
    set blocking(value: string);
    /** @deprecated */
    charset: string;
    /**
     * The **`crossOrigin`** property of the HTMLLinkElement interface specifies the Cross-Origin Resource Sharing (CORS) setting to use when retrieving the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/crossOrigin)
     */
    crossOrigin: string | null;
    /**
     * The **`disabled`** property of the HTMLLinkElement interface is a boolean value that represents whether the link is disabled. It only has an effect with style sheet links (rel property set to stylesheet).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`fetchPriority`** property of the HTMLLinkElement interface represents a hint to the browser indicating how it should prioritize fetching a particular resource relative to other resources of the same type. It reflects the <link> element's fetchpriority content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/fetchPriority)
     */
    fetchPriority: "high" | "low" | "auto";
    /**
     * The **`href`** property of the HTMLLinkElement interface contains a string that is the URL associated with the link.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/href)
     */
    href: string;
    /**
     * The **`hreflang`** property of the HTMLLinkElement interface is used to indicate the language and the geographical targeting of a page. This hint can be used by browsers to select the more appropriate page or to improve SEO.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/hreflang)
     */
    hreflang: string;
    /**
     * The **`imageSizes`** property of the HTMLLinkElement interface indicates the size and conditions for the preloaded images defined by the imageSrcset property. It reflects the value of the <link> element's imagesizes attribute. This property can retrieve or set the imagesizes attribute value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/imageSizes)
     */
    imageSizes: string;
    /**
     * The **`imageSrcset`** property of the HTMLLinkElement interface is a string which identifies one or more comma-separated image candidate strings. This property reflects the value of the <link> element's imagesrcset attribute. This property can retrieved or set the imagesrcset attribute value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/imageSrcset)
     */
    imageSrcset: string;
    /**
     * The **`integrity`** property of the HTMLLinkElement interface is a string containing inline metadata that a browser can use to verify that a fetched resource has been delivered without unexpected manipulation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/integrity)
     */
    integrity: string;
    /**
     * The **`media`** property of the HTMLLinkElement interface is a string representing a list of one or more media formats to which the resource applies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/media)
     */
    media: string;
    /**
     * The **`referrerPolicy`** property of the HTMLLinkElement interface reflects the HTML referrerpolicy attribute of the <link> element defining which referrer is sent when fetching the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/referrerPolicy)
     */
    referrerPolicy: string;
    /**
     * The **`rel`** property of the HTMLLinkElement interface reflects the rel attribute. It is a string containing a space-separated list of link types indicating the relationship between the resource represented by the <link> element and the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/rel)
     */
    rel: string;
    /**
     * The read-only **`relList`** property of the HTMLLinkElement returns a live DOMTokenList object containing the set of link types indicating the relationship between the resource represented by the <link> element and the current document. It reflects the <link> element's rel content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/relList)
     */
    get relList(): DOMTokenList;
    set relList(value: string);
    /** @deprecated */
    rev: string;
    /**
     * The read-only **`sizes`** property of the HTMLLinkElement interface defines the sizes of the icons for visual media contained in the resource. It reflects the <link> element's sizes attribute, which takes a list of space-separated sizes, each in the format <width in pixels>x<height in pixels>, or the keyword any.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/sizes)
     */
    get sizes(): DOMTokenList;
    set sizes(value: string);
    /** @deprecated */
    target: string;
    /**
     * The **`type`** property of the HTMLLinkElement interface is a string that reflects the MIME type of the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/type)
     */
    type: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLinkElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLLinkElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLLinkElement: {
    prototype: HTMLLinkElement;
    new(): HTMLLinkElement;
};

/**
 * The **`HTMLMapElement`** interface provides special properties and methods (beyond those of the regular object HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of map elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMapElement)
 */
interface HTMLMapElement extends HTMLElement {
    /**
     * The **`areas`** read-only property of the HTMLMapElement interface returns a collection of <area> elements associated with the <map> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMapElement/areas)
     */
    readonly areas: HTMLCollection;
    /**
     * The **`name`** property of the HTMLMapElement represents the unique name <map> element. Its value can be used with the useMap attribute of the <img> element to reference a <map> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMapElement/name)
     */
    name: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMapElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMapElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLMapElement: {
    prototype: HTMLMapElement;
    new(): HTMLMapElement;
};

/**
 * The **`HTMLMarqueeElement`** interface provides methods to manipulate <marquee> elements.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMarqueeElement)
 */
interface HTMLMarqueeElement extends HTMLElement {
    /** @deprecated */
    behavior: string;
    /** @deprecated */
    bgColor: string;
    /** @deprecated */
    direction: string;
    /** @deprecated */
    height: string;
    /** @deprecated */
    hspace: number;
    /** @deprecated */
    loop: number;
    /** @deprecated */
    scrollAmount: number;
    /** @deprecated */
    scrollDelay: number;
    /** @deprecated */
    trueSpeed: boolean;
    /** @deprecated */
    vspace: number;
    /** @deprecated */
    width: string;
    /** @deprecated */
    start(): void;
    /** @deprecated */
    stop(): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMarqueeElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMarqueeElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var HTMLMarqueeElement: {
    prototype: HTMLMarqueeElement;
    new(): HTMLMarqueeElement;
};

interface HTMLMediaElementEventMap extends HTMLElementEventMap {
    "encrypted": MediaEncryptedEvent;
    "waitingforkey": Event;
}

/**
 * The **`HTMLMediaElement`** interface adds to HTMLElement the properties and methods needed to support basic media-related capabilities that are common to audio and video.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement)
 */
interface HTMLMediaElement extends HTMLElement {
    /**
     * The **`HTMLMediaElement.autoplay`** property reflects the autoplay HTML attribute, indicating whether playback should automatically begin as soon as enough media is available to do so without interruption.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/autoplay)
     */
    autoplay: boolean;
    /**
     * The **`buffered`** read-only property of HTMLMediaElement objects returns a new static normalized TimeRanges object that represents the ranges of the media resource, if any, that the user agent has buffered at the moment the buffered property is accessed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/buffered)
     */
    readonly buffered: TimeRanges;
    /**
     * The **`HTMLMediaElement.controls`** property reflects the controls HTML attribute, which controls whether user interface controls for playing the media item will be displayed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/controls)
     */
    controls: boolean;
    /**
     * The **`HTMLMediaElement.crossOrigin`** property is the CORS setting for this media element. See CORS settings attributes for details.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/crossOrigin)
     */
    crossOrigin: string | null;
    /**
     * The **`HTMLMediaElement.currentSrc`** property contains the absolute URL of the chosen media resource. This could happen, for example, if the web server selects a media file based on the resolution of the user's display. The value is an empty string if the networkState property is EMPTY.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/currentSrc)
     */
    readonly currentSrc: string;
    /**
     * The HTMLMediaElement interface's **`currentTime`** property specifies the current playback time in seconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/currentTime)
     */
    currentTime: number;
    /**
     * The **`HTMLMediaElement.defaultMuted`** property reflects the muted HTML attribute, which indicates whether the media element's audio output should be muted by default. This property has no dynamic effect. To mute and unmute the audio output, use the muted property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/defaultMuted)
     */
    defaultMuted: boolean;
    /**
     * The **`HTMLMediaElement.defaultPlaybackRate`** property indicates the default playback rate for the media.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/defaultPlaybackRate)
     */
    defaultPlaybackRate: number;
    /**
     * The **`disableRemotePlayback`** property of the HTMLMediaElement interface determines whether the media element is allowed to have a remote playback UI.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/disableRemotePlayback)
     */
    disableRemotePlayback: boolean;
    /**
     * The read-only HTMLMediaElement property **`duration`** indicates the length of the element's media in seconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/duration)
     */
    readonly duration: number;
    /**
     * The **`HTMLMediaElement.ended`** property indicates whether the media element has ended playback.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/ended)
     */
    readonly ended: boolean;
    /**
     * The **`HTMLMediaElement.error`** property is the MediaError object for the most recent error, or null if there has not been an error. When an error event is received by the element, you can determine details about what happened by examining this object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/error)
     */
    readonly error: MediaError | null;
    /**
     * The **`HTMLMediaElement.loop`** property reflects the loop HTML attribute, which controls whether the media element should start over when it reaches the end.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loop)
     */
    loop: boolean;
    /**
     * The read-only **`HTMLMediaElement.mediaKeys`** property returns a MediaKeys object, that is a set of keys that the element can use for decryption of media data during playback.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/mediaKeys)
     */
    readonly mediaKeys: MediaKeys | null;
    /**
     * The **`HTMLMediaElement.muted`** property indicates whether the media element is muted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/muted)
     */
    muted: boolean;
    /**
     * The **`HTMLMediaElement.networkState`** property indicates the current state of the fetching of media over the network.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/networkState)
     */
    readonly networkState: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/encrypted_event) */
    onencrypted: ((this: HTMLMediaElement, ev: MediaEncryptedEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/waitingforkey_event) */
    onwaitingforkey: ((this: HTMLMediaElement, ev: Event) => any) | null;
    /**
     * The read-only **`HTMLMediaElement.paused`** property tells whether the media element is paused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/paused)
     */
    readonly paused: boolean;
    /**
     * The **`HTMLMediaElement.playbackRate`** property sets the rate at which the media is being played back. This is used to implement user controls for fast forward, slow motion, and so forth. The normal playback rate is multiplied by this value to obtain the current rate, so a value of 1.0 indicates normal speed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/playbackRate)
     */
    playbackRate: number;
    /**
     * The **`played`** read-only property of the HTMLMediaElement interface indicates the time ranges the resource, an <audio> or <video> media file, has played. It returns a new TimeRanges object that contains the ranges of the media source that the browser has played, if any, at the time the attribute is evaluated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/played)
     */
    readonly played: TimeRanges;
    /**
     * The **`preload`** property of the HTMLMediaElement interface is a string that provides a hint to the browser about what the author thinks will lead to the best user experience.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/preload)
     */
    preload: "none" | "metadata" | "auto" | "";
    /**
     * The **`HTMLMediaElement.preservesPitch`** property determines whether or not the browser should adjust the pitch of the audio to compensate for changes to the playback rate made by setting HTMLMediaElement.playbackRate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/preservesPitch)
     */
    preservesPitch: boolean;
    /**
     * The **`HTMLMediaElement.readyState`** property indicates the readiness state of the media.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/readyState)
     */
    readonly readyState: number;
    /**
     * The **`remote`** read-only property of the HTMLMediaElement interface returns the RemotePlayback object associated with the media element. The RemotePlayback object allow the control of remote devices playing the media.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/remote)
     */
    readonly remote: RemotePlayback;
    /**
     * The **`seekable`** read-only property of HTMLMediaElement objects returns a new static normalized TimeRanges object that represents the ranges of the media resource, if any, that the user agent is able to seek to at the time seekable property is accessed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/seekable)
     */
    readonly seekable: TimeRanges;
    /**
     * The **`seeking`** read-only property of the HTMLMediaElement interface is a Boolean indicating whether the resource, the <audio> or <video>, is in the process of seeking to a new position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/seeking)
     */
    readonly seeking: boolean;
    /**
     * The **`sinkId`** read-only property of the HTMLMediaElement interface returns a string that is the unique ID of the device to be used for playing audio output.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/sinkId)
     */
    readonly sinkId: string;
    /**
     * The **`HTMLMediaElement.src`** property reflects the value of the HTML media element's src attribute, which indicates the URL of a media resource to use in the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/src)
     */
    src: string;
    /**
     * The **`srcObject`** property of the HTMLMediaElement interface sets or returns the object which serves as the source of the media associated with the HTMLMediaElement, or null if not assigned.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/srcObject)
     */
    srcObject: MediaProvider | null;
    /**
     * The read-only **`textTracks`** property on HTMLMediaElement objects returns a TextTrackList object listing all of the TextTrack objects representing the media element's text tracks, in the same order as in the list of text tracks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/textTracks)
     */
    readonly textTracks: TextTrackList;
    /**
     * The **`HTMLMediaElement.volume`** property sets the volume at which the media will be played.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/volume)
     */
    volume: number;
    /**
     * The **`addTextTrack()`** method of the HTMLMediaElement interface creates a new TextTrack object and adds it to the media element. It fires an addtrack event on this media element's textTracks. This method can't be used on a TextTrackList interface, only an HTMLMediaElement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/addTextTrack)
     */
    addTextTrack(kind: TextTrackKind, label?: string, language?: string): TextTrack;
    /**
     * The HTMLMediaElement method **`canPlayType()`** reports how likely it is that the current browser will be able to play media of a given MIME type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/canPlayType)
     */
    canPlayType(type: string): CanPlayTypeResult;
    /**
     * The **`HTMLMediaElement.fastSeek()`** method quickly seeks the media to the new time with precision tradeoff.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/fastSeek)
     */
    fastSeek(time: number): void;
    /**
     * The HTMLMediaElement method **`load()`** resets the media element to its initial state and begins the process of selecting a media source and loading the media in preparation for playback to begin at the beginning.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/load)
     */
    load(): void;
    /**
     * The **`HTMLMediaElement.pause()`** method will pause playback of the media, if the media is already in a paused state this method will have no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/pause)
     */
    pause(): void;
    /**
     * The HTMLMediaElement **`play()`** method attempts to begin playback of the media. It returns a Promise which is resolved when playback has been successfully started.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/play)
     */
    play(): Promise<void>;
    /**
     * The **`setMediaKeys()`** method of the HTMLMediaElement interface sets the MediaKeys that will be used to decrypt media during playback.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/setMediaKeys)
     */
    setMediaKeys(mediaKeys: MediaKeys | null): Promise<void>;
    /**
     * The **`setSinkId()`** method of the HTMLMediaElement interface sets the ID of the audio device to use for output and returns a Promise.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/setSinkId)
     */
    setSinkId(sinkId: string): Promise<void>;
    readonly NETWORK_EMPTY: 0;
    readonly NETWORK_IDLE: 1;
    readonly NETWORK_LOADING: 2;
    readonly NETWORK_NO_SOURCE: 3;
    readonly HAVE_NOTHING: 0;
    readonly HAVE_METADATA: 1;
    readonly HAVE_CURRENT_DATA: 2;
    readonly HAVE_FUTURE_DATA: 3;
    readonly HAVE_ENOUGH_DATA: 4;
    addEventListener<K extends keyof HTMLMediaElementEventMap>(type: K, listener: (this: HTMLMediaElement, ev: HTMLMediaElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLMediaElementEventMap>(type: K, listener: (this: HTMLMediaElement, ev: HTMLMediaElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLMediaElement: {
    prototype: HTMLMediaElement;
    new(): HTMLMediaElement;
    readonly NETWORK_EMPTY: 0;
    readonly NETWORK_IDLE: 1;
    readonly NETWORK_LOADING: 2;
    readonly NETWORK_NO_SOURCE: 3;
    readonly HAVE_NOTHING: 0;
    readonly HAVE_METADATA: 1;
    readonly HAVE_CURRENT_DATA: 2;
    readonly HAVE_FUTURE_DATA: 3;
    readonly HAVE_ENOUGH_DATA: 4;
};

/**
 * The **`HTMLMenuElement`** interface provides additional properties (beyond those inherited from the HTMLElement interface) for manipulating a <menu> element. <menu> is a semantic alternative to the <ul> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMenuElement)
 */
interface HTMLMenuElement extends HTMLElement {
    /**
     * The **`compact`** property of the HTMLMenuElement interface indicates that spacing between list items should be reduced. The exact handling of the compact attribute is browser-specific. Instead of using this property, consider using CSS line-height instead.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMenuElement/compact)
     */
    compact: boolean;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMenuElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMenuElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLMenuElement: {
    prototype: HTMLMenuElement;
    new(): HTMLMenuElement;
};

/**
 * The **`HTMLMetaElement`** interface contains descriptive metadata about a document provided in HTML as <meta> elements. This interface inherits all of the properties and methods described in the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMetaElement)
 */
interface HTMLMetaElement extends HTMLElement {
    /**
     * The **`HTMLMetaElement.content`** property gets or sets the content attribute of pragma directives and named <meta> data in conjunction with HTMLMetaElement.name or HTMLMetaElement.httpEquiv. For more information, see the content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMetaElement/content)
     */
    content: string;
    /**
     * The **`HTMLMetaElement.httpEquiv`** property gets or sets the pragma directive or an HTTP response header name for the HTMLMetaElement.content attribute. For more details on the possible values, see the http-equiv attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMetaElement/httpEquiv)
     */
    httpEquiv: string;
    /**
     * The **`HTMLMetaElement.media`** property enables specifying the media for theme-color metadata.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMetaElement/media)
     */
    media: string;
    /**
     * The **`HTMLMetaElement.name`** property is used in combination with HTMLMetaElement.content to define the name-value pairs for the metadata of a document. The name attribute defines the metadata name and the content attribute defines the value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMetaElement/name)
     */
    name: string;
    /**
     * The **`HTMLMetaElement.scheme`** property defines the scheme of the value in the HTMLMetaElement.content attribute. The scheme property was created to enable providing additional information to be used to interpret the value of the content property. The scheme property takes as its value a scheme format (i.e., YYYY-MM-DD) or scheme format name (i.e., ISBN), or a URI providing more information regarding the scheme format. The scheme defines the format of the value of the content attribute. The scheme content is interpreted as an extension of the element's HTMLMetaElement.name if a browser or user agent recognizes the scheme.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMetaElement/scheme)
     */
    scheme: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMetaElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMetaElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLMetaElement: {
    prototype: HTMLMetaElement;
    new(): HTMLMetaElement;
};

/**
 * The HTML <meter> elements expose the **`HTMLMeterElement`** interface, which provides special properties and methods (beyond the HTMLElement object interface they also have available to them by inheritance) for manipulating the layout and presentation of <meter> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement)
 */
interface HTMLMeterElement extends HTMLElement {
    /**
     * The **`high`** property of the HTMLMeterElement interface represents the high boundary of the <meter> element as a floating-point number. It reflects the element's high attribute, or the value of max if not defined. The value of high is clamped by the low and max values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/high)
     */
    high: number;
    /**
     * The **`HTMLMeterElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <meter> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement>;
    /**
     * The **`low`** property of the HTMLMeterElement interface represents the low boundary of the <meter> element as a floating-point number. It reflects the element's low attribute, or the value of min if not defined. The value of low is clamped by the min and max values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/low)
     */
    low: number;
    /**
     * The **`max`** property of the HTMLMeterElement interface represents the maximum value of the <meter> element as a floating-point number. It reflects the element's max attribute, or the min value if no max is set, or 1 if neither the min or the max is defined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/max)
     */
    max: number;
    /**
     * The **`min`** property of the HTMLMeterElement interface represents the minimum value of the <meter> element as a floating-point number. It reflects the element's min attribute, or 0 if no min is defined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/min)
     */
    min: number;
    /**
     * The **`optimum`** property of the HTMLMeterElement interface represents the optimum boundary of the <meter> element as a floating-point number. It reflects the element's optimum attribute, or the midpoint between min and max values if not defined. The value of optimum is clamped by the min and max values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/optimum)
     */
    optimum: number;
    /**
     * The **`value`** property of the HTMLMeterElement interface represents the current value of the <meter> element as a floating-point number. It reflects the element's value attribute. If no value is set, it is the HTMLMeterElement.min value or 0, whichever is greater.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMeterElement/value)
     */
    value: number;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMeterElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLMeterElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLMeterElement: {
    prototype: HTMLMeterElement;
    new(): HTMLMeterElement;
};

/**
 * The **`HTMLModElement`** interface provides special properties (beyond the regular methods and properties available through the HTMLElement interface they also have available to them by inheritance) for manipulating modification elements, that is <del> and <ins>.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLModElement)
 */
interface HTMLModElement extends HTMLElement {
    /**
     * The **`cite`** property of the HTMLModElement interface indicates the URL of the resource explaining the modification. It reflects the cite attribute of the <del> element and <ins> elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLModElement/cite)
     */
    cite: string;
    /**
     * The **`dateTime`** property of the HTMLModElement interface is a string containing a machine-readable date with an optional time value. It reflects the datetime HTML attribute of the <del> and <ins> elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLModElement/dateTime)
     */
    dateTime: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLModElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLModElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLModElement: {
    prototype: HTMLModElement;
    new(): HTMLModElement;
};

/**
 * The **`HTMLOListElement`** interface provides special properties (beyond those defined on the regular HTMLElement interface it also has available to it by inheritance) for manipulating ordered list elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOListElement)
 */
interface HTMLOListElement extends HTMLElement {
    /**
     * The **`compact`** property of the HTMLOListElement interface indicates that spacing between list items should be reduced. The exact handling of the compact attribute is browser-specific. Instead of using this property, consider using CSS line-height instead.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOListElement/compact)
     */
    compact: boolean;
    /**
     * The **`reversed`** property of the HTMLOListElement interface indicates order of a list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOListElement/reversed)
     */
    reversed: boolean;
    /**
     * The **`start`** property of the HTMLOListElement interface indicates starting value of the ordered list, with default value of 1.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOListElement/start)
     */
    start: number;
    /**
     * The **`type`** property of the HTMLOListElement interface indicates the kind of marker to be used to display ordered list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOListElement/type)
     */
    type: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLOListElement: {
    prototype: HTMLOListElement;
    new(): HTMLOListElement;
};

/**
 * The **`HTMLObjectElement`** interface provides special properties and methods (beyond those on the HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of <object> element, representing external resources.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement)
 */
interface HTMLObjectElement extends HTMLElement {
    /** @deprecated */
    align: string;
    /** @deprecated */
    archive: string;
    /** @deprecated */
    border: string;
    /** @deprecated */
    code: string;
    /** @deprecated */
    codeBase: string;
    /** @deprecated */
    codeType: string;
    /**
     * The **`contentDocument`** read-only property of the HTMLObjectElement interface Returns a Document representing the active document of the object element's nested browsing context, if any; otherwise null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/contentDocument)
     */
    readonly contentDocument: Document | null;
    /**
     * The **`contentWindow`** read-only property of the HTMLObjectElement interface returns a WindowProxy representing the window proxy of the object element's nested browsing context, if any; otherwise null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/contentWindow)
     */
    readonly contentWindow: WindowProxy | null;
    /**
     * The **`data`** property of the HTMLObjectElement interface returns a string that reflects the data HTML attribute, specifying the address of a resource's data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/data)
     */
    data: string;
    /** @deprecated */
    declare: boolean;
    /**
     * The **`form`** read-only property of the HTMLObjectElement interface returns an HTMLFormElement object that owns this <object>, or null if this object element is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`height`** property of the HTMLObjectElement interface Returns a string that reflects the height HTML attribute, specifying the displayed height of the resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/height)
     */
    height: string;
    /** @deprecated */
    hspace: number;
    /**
     * The **`name`** property of the HTMLObjectElement interface returns a string that reflects the name HTML attribute, specifying the name of the browsing context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/name)
     */
    name: string;
    /** @deprecated */
    standby: string;
    /**
     * The **`type`** property of the HTMLObjectElement interface returns a string that reflects the type HTML attribute, specifying the MIME type of the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/type)
     */
    type: string;
    /**
     * The **`useMap`** property of the HTMLObjectElement interface returns a string that reflects the usemap HTML attribute, specifying a <map> element to use.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/useMap)
     */
    useMap: string;
    /**
     * The **`validationMessage`** read-only property of the HTMLObjectElement interface returns a string representing a localized message that describes the validation constraints that the control does not satisfy (if any). This is the empty string if the control is not a candidate for constraint validation (willValidate is false), or it satisfies its constraints.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLObjectElement interface returns a ValidityState object that represents the validity states this element is in. Although <object> elements are never candidates for constraint validation, the validity state may still be invalid if a custom validity message has been set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/validity)
     */
    readonly validity: ValidityState;
    /** @deprecated */
    vspace: number;
    /**
     * The **`width`** property of the HTMLObjectElement interface returns a string that reflects the width HTML attribute, specifying the displayed width of the resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/width)
     */
    width: string;
    /**
     * The **`willValidate`** read-only property of the HTMLObjectElement interface returns false, because <object> elements are not candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`checkValidity()`** method of the HTMLObjectElement interface checks if the element is valid, but always returns true because <object> elements are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`getSVGDocument()`** method of the HTMLObjectElement interface returns the Document object of the embedded SVG.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/getSVGDocument)
     */
    getSVGDocument(): Document | null;
    /**
     * The **`reportValidity()`** method of the HTMLObjectElement interface performs the same validity checking steps as the checkValidity() method. It always returns true because <object> elements are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`setCustomValidity()`** method of the HTMLObjectElement interface sets a custom validity message for the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLObjectElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLObjectElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLObjectElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLObjectElement: {
    prototype: HTMLObjectElement;
    new(): HTMLObjectElement;
};

/**
 * The **`HTMLOptGroupElement`** interface provides special properties and methods (beyond the regular HTMLElement object interface they also have available to them by inheritance) for manipulating the layout and presentation of <optgroup> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptGroupElement)
 */
interface HTMLOptGroupElement extends HTMLElement {
    /**
     * The **`disabled`** property of the HTMLOptGroupElement interface is a boolean value that reflects the <optgroup> element's disabled attribute, which indicates whether the control is disabled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptGroupElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`label`** property of the HTMLOptGroupElement interface is a string value that reflects the <optgroup> element's label attribute, which provides a textual label to the group of options.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptGroupElement/label)
     */
    label: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOptGroupElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOptGroupElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLOptGroupElement: {
    prototype: HTMLOptGroupElement;
    new(): HTMLOptGroupElement;
};

/**
 * The **`HTMLOptionElement`** interface represents <option> elements and inherits all properties and methods of the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement)
 */
interface HTMLOptionElement extends HTMLElement {
    /**
     * The **`defaultSelected`** property of the HTMLOptionElement interface specifies the default selected state of the element. This property reflects the <option> element's selected attribute. The presence of the selected attribute sets the defaultSelected property to true.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/defaultSelected)
     */
    defaultSelected: boolean;
    /**
     * The **`disabled`** property of the HTMLOptionElement is a boolean value that indicates whether the <option> element is unavailable to be selected. The property reflects the value of the disabled HTML attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`form`** read-only property of the HTMLOptionElement interface returns an HTMLFormElement object that owns the HTMLSelectElement associated with this <option>, or null if this option is not associated with a <select> owned by a form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The read-only **`index`** property of the HTMLOptionElement interface specifies the 0-based index of the element; that is, the position of the <option> within the list of options it belongs to, in tree-order, as an integer. If the <option> is not part of an option-list, the value is 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/index)
     */
    readonly index: number;
    /**
     * The **`label`** property of the HTMLOptionElement represents the text displayed for an option in a <select> element or as part of a list of suggestions in a <datalist> element. It reflects the <option> element's label attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/label)
     */
    label: string;
    /**
     * The **`selected`** property of the HTMLOptionElement interface specifies the current selectedness of the element; that is, whether the <option> is selected or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/selected)
     */
    selected: boolean;
    /**
     * The **`text`** property of the HTMLOptionElement represents the text inside the <option> element. This property represents the same information as Node.textContent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/text)
     */
    text: string;
    /**
     * The **`value`** property of the HTMLOptionElement interface represents the value of the <option> element as a string, or the empty string if no value is set. It reflects the element's value attribute, if present. Otherwise, it returns or sets the contents of the element, similar to the textContent property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionElement/value)
     */
    value: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOptionElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOptionElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLOptionElement: {
    prototype: HTMLOptionElement;
    new(): HTMLOptionElement;
};

/**
 * The **`HTMLOptionsCollection`** interface represents a collection of <option> HTML elements (in document order) and offers methods and properties for selecting from the list as well as optionally altering its items. This object is returned only by the options property of select.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionsCollection)
 */
interface HTMLOptionsCollection extends HTMLCollectionOf<HTMLOptionElement> {
    /**
     * The **`length`** property of the HTMLOptionsCollection interface returns the number of <option> elements in the collection. The property can get or set the size of the collection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionsCollection/length)
     */
    length: number;
    /**
     * The **`selectedIndex`** property of the HTMLOptionsCollection interface is the numeric index of the first selected <option> element, if any, or −1 if no <option> is selected. Setting this property selects the option at that index and deselects all other options in this collection, while setting it to -1 deselects any currently selected elements. It is exactly equivalent to the selectedIndex property of the HTMLSelectElement that owns this collection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionsCollection/selectedIndex)
     */
    selectedIndex: number;
    /**
     * The **`add()`** method of the HTMLOptionsCollection interface adds an HTMLOptionElement or HTMLOptGroupElement to this HTMLOptionsCollection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionsCollection/add)
     */
    add(element: HTMLOptionElement | HTMLOptGroupElement, before?: HTMLElement | number | null): void;
    /**
     * The **`remove()`** method of the HTMLOptionsCollection interface removes the <option> element specified by the index from this collection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOptionsCollection/remove)
     */
    remove(index: number): void;
}

declare var HTMLOptionsCollection: {
    prototype: HTMLOptionsCollection;
    new(): HTMLOptionsCollection;
};

interface HTMLOrSVGElement {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/autofocus) */
    autofocus: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dataset) */
    readonly dataset: DOMStringMap;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/nonce) */
    nonce: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/tabIndex) */
    tabIndex: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/blur) */
    blur(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/focus) */
    focus(options?: FocusOptions): void;
}

/**
 * The **`HTMLOutputElement`** interface provides properties and methods (beyond those inherited from HTMLElement) for manipulating the layout and presentation of <output> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement)
 */
interface HTMLOutputElement extends HTMLElement {
    /**
     * The **`defaultValue`** property of the HTMLOutputElement interface represents the default text content of this <output> element. Getting and setting this value is equivalent to getting and setting textContent on the <output>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/defaultValue)
     */
    defaultValue: string;
    /**
     * The **`form`** read-only property of the HTMLOutputElement interface returns an HTMLFormElement object that owns this <output>, or null if this output is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The read-only **`htmlFor`** property of the HTMLOutputElement returns a live DOMTokenList object containing a list of ids of those elements contributing input values to (or otherwise affected) the calculation. It reflects the <output> element's for content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/htmlFor)
     */
    get htmlFor(): DOMTokenList;
    set htmlFor(value: string);
    /**
     * The **`HTMLOutputElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <output> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement>;
    /**
     * The **`name`** property of the HTMLOutputElement interface indicates the name of the <output> element. It reflects the element's name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/name)
     */
    name: string;
    /**
     * The **`type`** read-only property of the HTMLOutputElement interface returns the string "output".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/type)
     */
    readonly type: string;
    /**
     * The **`validationMessage`** read-only property of the HTMLOutputElement interface returns a string representing a localized message that describes the validation constraints that the <output> control does not satisfy (if any). This is the empty string as <output> elements are not candidates for constraint validation (HTMLOutputElement.willValidate is false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLOutputElement interface returns a ValidityState object that represents the validity states this element is in. Although <output> elements are never candidates for constraint validation, the validity state may still be invalid if a custom validity message has been set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`value`** property of the HTMLOutputElement interface represents the value of the <output> element as a string, or the empty string if no value is set. It returns or sets the contents of the element, similar to the textContent property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/value)
     */
    value: string;
    /**
     * The **`willValidate`** read-only property of the HTMLOutputElement interface returns false, because <output> elements are not candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`checkValidity()`** method of the HTMLOutputElement interface checks if the element is valid, but always returns true because <output> elements are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the HTMLOutputElement interface performs the same validity checking steps as the checkValidity() method. It always returns true because <output> elements are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`setCustomValidity()`** method of the HTMLOutputElement interface sets the custom validity message for the <output> element. Use the empty string to indicate that the element does not have a custom validity error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLOutputElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOutputElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLOutputElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLOutputElement: {
    prototype: HTMLOutputElement;
    new(): HTMLOutputElement;
};

/**
 * The **`HTMLParagraphElement`** interface provides special properties (beyond those of the regular HTMLElement object interface it inherits) for manipulating <p> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLParagraphElement)
 */
interface HTMLParagraphElement extends HTMLElement {
    /** @deprecated */
    align: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLParagraphElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLParagraphElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLParagraphElement: {
    prototype: HTMLParagraphElement;
    new(): HTMLParagraphElement;
};

/**
 * The **`HTMLParamElement`** interface provides special properties (beyond those of the regular HTMLElement object interface it inherits) for manipulating <param> elements, representing a pair of a key and a value that acts as a parameter for an <object> element.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLParamElement)
 */
interface HTMLParamElement extends HTMLElement {
    /** @deprecated */
    name: string;
    /** @deprecated */
    type: string;
    /** @deprecated */
    value: string;
    /** @deprecated */
    valueType: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLParamElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLParamElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var HTMLParamElement: {
    prototype: HTMLParamElement;
    new(): HTMLParamElement;
};

/**
 * The **`HTMLPictureElement`** interface represents a <picture> HTML element. It doesn't implement specific properties or methods.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLPictureElement)
 */
interface HTMLPictureElement extends HTMLElement {
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLPictureElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLPictureElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLPictureElement: {
    prototype: HTMLPictureElement;
    new(): HTMLPictureElement;
};

/**
 * The **`HTMLPreElement`** interface exposes specific properties and methods (beyond those of the HTMLElement interface it also has available to it by inheritance) for manipulating a block of preformatted text (<pre>).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLPreElement)
 */
interface HTMLPreElement extends HTMLElement {
    /** @deprecated */
    width: number;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLPreElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLPreElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLPreElement: {
    prototype: HTMLPreElement;
    new(): HTMLPreElement;
};

/**
 * The **`HTMLProgressElement`** interface provides special properties and methods (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of <progress> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLProgressElement)
 */
interface HTMLProgressElement extends HTMLElement {
    /**
     * The **`HTMLProgressElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <progress> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLProgressElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement>;
    /**
     * The **`max`** property of the HTMLProgressElement interface represents the upper bound of the <progress> element's range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLProgressElement/max)
     */
    max: number;
    /**
     * The **`position`** read-only property of the HTMLProgressElement interface returns current progress of the <progress> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLProgressElement/position)
     */
    readonly position: number;
    /**
     * The **`value`** property of the HTMLProgressElement interface represents the current progress of the <progress> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLProgressElement/value)
     */
    value: number;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLProgressElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLProgressElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLProgressElement: {
    prototype: HTMLProgressElement;
    new(): HTMLProgressElement;
};

/**
 * The **`HTMLQuoteElement`** interface provides special properties and methods (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating quoting elements, like <blockquote> and <q>, but not the <cite> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLQuoteElement)
 */
interface HTMLQuoteElement extends HTMLElement {
    /**
     * The **`cite`** property of the HTMLQuoteElement interface indicates the URL for the source of the quotation. It reflects the <q> element's cite attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLQuoteElement/cite)
     */
    cite: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLQuoteElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLQuoteElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLQuoteElement: {
    prototype: HTMLQuoteElement;
    new(): HTMLQuoteElement;
};

/**
 * HTML <script> elements expose the **`HTMLScriptElement`** interface, which provides special properties and methods for manipulating the behavior and execution of <script> elements (beyond the inherited HTMLElement interface).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement)
 */
interface HTMLScriptElement extends HTMLElement {
    /**
     * The **`async`** property of the HTMLScriptElement interface is a boolean value that controls how the script should be executed. For classic scripts, if the async property is set to true, the external script will be fetched in parallel to parsing and evaluated as soon as it is available. For module scripts, if the async property is set to true, the script and all their dependencies will be fetched in parallel to parsing and evaluated as soon as they are available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/async)
     */
    async: boolean;
    /**
     * The read-only **`blocking`** property of the HTMLScriptElement returns a live DOMTokenList object containing the operations that should be blocked on the fetching of an external resource. It reflects the <script> element's blocking content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/blocking)
     */
    get blocking(): DOMTokenList;
    set blocking(value: string);
    /** @deprecated */
    charset: string;
    /**
     * The **`crossOrigin`** property of the HTMLScriptElement interface reflects the Cross-Origin Resource Sharing settings for the script element. For classic scripts from other origins, this controls if full error information will be exposed. For module scripts, it controls the script itself and any script it imports. See CORS settings attributes for details.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/crossOrigin)
     */
    crossOrigin: string | null;
    /**
     * The **`defer`** property of the HTMLScriptElement interface is a boolean value that controls how the script should be executed. For classic scripts, if the defer property is set to true, the external script will be executed after the document has been parsed, but before firing DOMContentLoaded event. For module scripts, the defer property has no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/defer)
     */
    defer: boolean;
    /** @deprecated */
    event: string;
    /**
     * The **`fetchPriority`** property of the HTMLScriptElement interface represents a hint to the browser indicating how it should prioritize fetching an external script relative to other external scripts. It reflects the <script> element's fetchpriority content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/fetchPriority)
     */
    fetchPriority: "high" | "low" | "auto";
    /** @deprecated */
    htmlFor: string;
    /**
     * The **`integrity`** property of the HTMLScriptElement interface is a string that contains inline metadata that a browser can use to verify that a fetched resource has been delivered without unexpected manipulation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/integrity)
     */
    integrity: string;
    /**
     * The **`noModule`** property of the HTMLScriptElement interface is a boolean value that indicates whether the script should be executed in browsers that support ES modules. Practically, this can be used to serve fallback scripts to older browsers that do not support JavaScript modules.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/noModule)
     */
    noModule: boolean;
    /**
     * The **`referrerPolicy`** property of the HTMLScriptElement interface reflects the HTML referrerpolicy of the <script> element, which defines how the referrer is set when fetching the script and any scripts it imports.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/referrerPolicy)
     */
    referrerPolicy: string;
    /**
     * The **`src`** property of the HTMLScriptElement interface is a string representing the URL of an external script; this can be used as an alternative to embedding a script directly within a document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/src)
     */
    src: string;
    /**
     * The **`text`** property of the HTMLScriptElement interface represents the inline text content of the <script> element. It behaves in the same way as the textContent and innerText property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/text)
     */
    text: string;
    /**
     * The **`type`** property of the HTMLScriptElement interface is a string that reflects the type of the script.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/type)
     */
    type: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLScriptElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLScriptElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLScriptElement: {
    prototype: HTMLScriptElement;
    new(): HTMLScriptElement;
    /**
     * The **`supports()`** static method of the HTMLScriptElement interface provides a simple and consistent method to feature-detect what types of scripts are supported by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLScriptElement/supports_static)
     */
    supports(type: string): boolean;
};

/**
 * The **`HTMLSelectElement`** interface represents a <select> HTML Element. These elements also share all of the properties and methods of other HTML elements via the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement)
 */
interface HTMLSelectElement extends HTMLElement {
    /**
     * The **`autocomplete`** property of the HTMLSelectElement interface indicates whether the value of the control can be automatically completed by the browser. It reflects the <select> element's autocomplete attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/autocomplete)
     */
    autocomplete: AutoFill;
    /**
     * The **`HTMLSelectElement.disabled`** property is a boolean value that reflects the disabled HTML attribute, which indicates whether the control is disabled. If it is disabled, it does not accept clicks. A disabled element is unusable and un-clickable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`form`** read-only property of the HTMLSelectElement interface returns an HTMLFormElement object that owns this <select>, or null if this select is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`HTMLSelectElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <select> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement>;
    /**
     * The **`length`** property of the HTMLSelectElement interface specifies the number of <option> elements in the <select> element. It represents the number of nodes in the options collection. On setting, it acts as (HTMLOptionsCollection.length).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/length)
     */
    length: number;
    /**
     * The **`multiple`** property of the HTMLSelectElement interface specifies that the user may select more than one option from the list of options. It reflects the <select> element's multiple attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/multiple)
     */
    multiple: boolean;
    /**
     * The **`name`** property of the HTMLSelectElement interface indicates the name of the <select> element. It reflects the element's name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/name)
     */
    name: string;
    /**
     * The **`HTMLSelectElement.options`** read-only property returns a HTMLOptionsCollection of the <option> elements contained by the <select> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/options)
     */
    readonly options: HTMLOptionsCollection;
    /**
     * The **`required`** property of the HTMLSelectElement interface specifies that the user must select an option with a non-empty string value before submitting a form. It reflects the <select> element's required attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/required)
     */
    required: boolean;
    /**
     * The **`selectedIndex`** property of the HTMLSelectElement interface is the numeric index of the first selected <option> element in a <select> element, if any, or −1 if no <option> is selected. Setting this property selects the option at that index and deselects all other options, while setting it to -1 deselects any currently selected options.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/selectedIndex)
     */
    selectedIndex: number;
    /**
     * The read-only HTMLSelectElement property **`selectedOptions`** contains a list of the <option> elements contained within the <select> element that are currently selected. The list of selected options is an HTMLCollection object with one entry per currently selected option.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/selectedOptions)
     */
    readonly selectedOptions: HTMLCollectionOf<HTMLOptionElement>;
    /**
     * The **`size`** property of the HTMLSelectElement interface specifies the number of options, or rows, that should be visible at one time. It reflects the <select> element's size attribute. If omitted, the value is 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/size)
     */
    size: number;
    /**
     * The **`HTMLSelectElement.type`** read-only property returns the form control's type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/type)
     */
    readonly type: "select-one" | "select-multiple";
    /**
     * The **`validationMessage`** read-only property of the HTMLSelectElement interface returns a string representing a localized message that describes the validation constraints that the <select> control does not satisfy (if any). This is the empty string if the control is not a candidate for constraint validation (HTMLSelectElement.willValidate is false), or it satisfies its constraints.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLSelectElement interface returns a ValidityState object that represents the validity states this element is in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`HTMLSelectElement.value`** property contains the value of the first selected <option> element associated with this <select> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/value)
     */
    value: string;
    /**
     * The **`willValidate`** read-only property of the HTMLSelectElement interface indicates whether the <select> element is a candidate for constraint validation. It is false if any conditions bar it from constraint validation, such as when its disabled property is true.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`HTMLSelectElement.add()`** method adds an element to the collection of option elements for this select element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/add)
     */
    add(element: HTMLOptionElement | HTMLOptGroupElement, before?: HTMLElement | number | null): void;
    /**
     * The **`checkValidity()`** method of the HTMLSelectElement interface returns a boolean value which indicates if the element meets any constraint validation rules applied to it. If false, the method also fires an invalid event on the element. Because there's no default browser behavior for checkValidity(), canceling this invalid event has no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`HTMLSelectElement.item()`** method returns the Element corresponding to the HTMLOptionElement whose position in the options list corresponds to the index given in the parameter, or null if there are none.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/item)
     */
    item(index: number): HTMLOptionElement | null;
    /**
     * The **`HTMLSelectElement.namedItem()`** method returns the HTMLOptionElement corresponding to the HTMLOptionElement whose name or id match the specified name, or null if no option matches.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/namedItem)
     */
    namedItem(name: string): HTMLOptionElement | null;
    /**
     * The **`HTMLSelectElement.remove()`** method removes the element at the specified index from the options collection for this select element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/remove)
     */
    remove(): void;
    remove(index: number): void;
    /**
     * The **`reportValidity()`** method of the HTMLSelectElement interface performs the same validity checking steps as the checkValidity() method. In addition, if the invalid event is not canceled, the browser displays the problem to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`HTMLSelectElement.setCustomValidity()`** method sets the custom validity message for the selection element to the specified message. Use the empty string to indicate that the element does not have a custom validity error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    /**
     * The **`HTMLSelectElement.showPicker()`** method displays the browser picker for a select element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSelectElement/showPicker)
     */
    showPicker(): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSelectElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSelectElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
    [name: number]: HTMLOptionElement | HTMLOptGroupElement;
}

declare var HTMLSelectElement: {
    prototype: HTMLSelectElement;
    new(): HTMLSelectElement;
};

/**
 * The **`HTMLSlotElement`** interface of the Shadow DOM API enables access to the name and assigned nodes of an HTML <slot> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement)
 */
interface HTMLSlotElement extends HTMLElement {
    /**
     * The **`name`** property of the HTMLSlotElement interface returns or sets the slot name. A slot is a placeholder inside a web component that users can fill with their own markup.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement/name)
     */
    name: string;
    /**
     * The **`assign()`** method of the HTMLSlotElement interface sets the slot's manually assigned nodes to an ordered set of slottables. The manually assigned nodes set is initially empty until nodes are assigned using assign().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement/assign)
     */
    assign(...nodes: (Element | Text)[]): void;
    /**
     * The **`assignedElements()`** method of the HTMLSlotElement interface returns a sequence of the elements assigned to this slot (and no other nodes).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement/assignedElements)
     */
    assignedElements(options?: AssignedNodesOptions): Element[];
    /**
     * The **`assignedNodes()`** method of the HTMLSlotElement interface returns a sequence of the nodes assigned to this slot.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement/assignedNodes)
     */
    assignedNodes(options?: AssignedNodesOptions): Node[];
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSlotElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSlotElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLSlotElement: {
    prototype: HTMLSlotElement;
    new(): HTMLSlotElement;
};

/**
 * The **`HTMLSourceElement`** interface provides special properties (beyond the regular HTMLElement object interface it also has available to it by inheritance) for manipulating <source> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement)
 */
interface HTMLSourceElement extends HTMLElement {
    /**
     * The **`height`** property of the HTMLSourceElement interface is a non-negative number indicating the height of the image resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/height)
     */
    height: number;
    /**
     * The **`media`** property of the HTMLSourceElement interface is a string representing the intended destination medium for the resource. The value is a media query, which is a comma separated list of media-types, media-features, and logical operators.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/media)
     */
    media: string;
    /**
     * The **`sizes`** property of the HTMLSourceElement interface is a string representing a list of one or more sizes, representing sizes between breakpoints, to which the resource applies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/sizes)
     */
    sizes: string;
    /**
     * The **`src`** property of the HTMLSourceElement interface is a string indicating the URL of a media resource to use as the source for the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/src)
     */
    src: string;
    /**
     * The **`srcset`** property of the HTMLSourceElement interface is a string containing a comma-separated list of candidate images.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/srcset)
     */
    srcset: string;
    /**
     * The **`type`** property of the HTMLSourceElement interface is a string representing the MIME type of the media resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/type)
     */
    type: string;
    /**
     * The **`width`** property of the HTMLSourceElement interface is a non-negative number indicating the width of the image resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSourceElement/width)
     */
    width: number;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSourceElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSourceElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLSourceElement: {
    prototype: HTMLSourceElement;
    new(): HTMLSourceElement;
};

/**
 * The **`HTMLSpanElement`** interface represents a <span> element and derives from the HTMLElement interface, but without implementing any additional properties or methods.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSpanElement)
 */
interface HTMLSpanElement extends HTMLElement {
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSpanElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLSpanElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLSpanElement: {
    prototype: HTMLSpanElement;
    new(): HTMLSpanElement;
};

/**
 * The **`HTMLStyleElement`** interface represents a <style> element. It inherits properties and methods from its parent, HTMLElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLStyleElement)
 */
interface HTMLStyleElement extends HTMLElement, LinkStyle {
    /**
     * The read-only **`blocking`** property of the HTMLStyleElement returns a live DOMTokenList object containing the operations that should be blocked on the fetching of an external resource. It reflects the <style> element's blocking content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLStyleElement/blocking)
     */
    get blocking(): DOMTokenList;
    set blocking(value: string);
    /**
     * The **`HTMLStyleElement.disabled`** property can be used to get and set whether the stylesheet is disabled (true) or not (false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLStyleElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`HTMLStyleElement.media`** property specifies the intended destination medium for style information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLStyleElement/media)
     */
    media: string;
    /**
     * The **`HTMLStyleElement.type`** property returns the type of the current style. The value mirrors the HTML <style> element's type attribute.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLStyleElement/type)
     */
    type: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLStyleElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLStyleElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLStyleElement: {
    prototype: HTMLStyleElement;
    new(): HTMLStyleElement;
};

/**
 * The **`HTMLTableCaptionElement`** interface provides special properties (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating table <caption> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCaptionElement)
 */
interface HTMLTableCaptionElement extends HTMLElement {
    /**
     * The **`align`** property of the HTMLTableCaptionElement interface is a string indicating how to horizontally align text in the <caption> table element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCaptionElement/align)
     */
    align: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableCaptionElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableCaptionElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTableCaptionElement: {
    prototype: HTMLTableCaptionElement;
    new(): HTMLTableCaptionElement;
};

/**
 * The **`HTMLTableCellElement`** interface provides special properties and methods (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of table cells, either header cells (<th>) or data cells (<td>), in an HTML document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement)
 */
interface HTMLTableCellElement extends HTMLElement {
    /**
     * The **`abbr`** property of the HTMLTableCellElement interface indicates an abbreviation associated with the cell. If the cell does not represent a header cell <th>, it is ignored.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/abbr)
     */
    abbr: string;
    /**
     * The **`align`** property of the HTMLTableCellElement interface is a string indicating how to horizontally align text in the <th> or <td> table cell.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/align)
     */
    align: string;
    /** @deprecated */
    axis: string;
    /**
     * The **`HTMLTableCellElement.bgColor`** property is used to set the background color of a cell or get the value of the obsolete bgColor attribute, if present.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/bgColor)
     */
    bgColor: string;
    /**
     * The **`cellIndex`** read-only property of the HTMLTableCellElement interface represents the position of a cell within its row (<tr>). The first cell has an index of 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/cellIndex)
     */
    readonly cellIndex: number;
    /**
     * The **`ch`** property of the HTMLTableCellElement interface does nothing. It reflects the char attribute of the cell element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/ch)
     */
    ch: string;
    /**
     * The **`chOff`** property of the HTMLTableCellElement interface does nothing. It reflects the charoff attribute of the cell element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/chOff)
     */
    chOff: string;
    /**
     * The **`colSpan`** property of the HTMLTableCellElement interface represents the number of columns this cell must span; this lets the cell occupy space across multiple columns of the table. It reflects the colspan attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/colSpan)
     */
    colSpan: number;
    /**
     * The **`headers`** property of the HTMLTableCellElement interface contains a list of IDs of <th> elements that are headers for this specific cell.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/headers)
     */
    headers: string;
    /** @deprecated */
    height: string;
    /**
     * The **`noWrap`** property of the HTMLTableCellElement interface returns a Boolean value indicating if the text of the cell may be wrapped on several lines or not.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/noWrap)
     */
    noWrap: boolean;
    /**
     * The **`rowSpan`** property of the HTMLTableCellElement interface represents the number of rows this cell must span; this lets the cell occupy space across multiple rows of the table. It reflects the rowspan attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/rowSpan)
     */
    rowSpan: number;
    /**
     * The **`scope`** property of the HTMLTableCellElement interface indicates the scope of a <th> cell.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/scope)
     */
    scope: string;
    /**
     * The **`vAlign`** property of the HTMLTableCellElement interface is a string indicating how to vertically align text in a <th> or <td> table cell.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableCellElement/vAlign)
     */
    vAlign: string;
    /** @deprecated */
    width: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableCellElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableCellElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTableCellElement: {
    prototype: HTMLTableCellElement;
    new(): HTMLTableCellElement;
};

/**
 * The **`HTMLTableColElement`** interface provides properties for manipulating single or grouped table column elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableColElement)
 */
interface HTMLTableColElement extends HTMLElement {
    /**
     * The **`align`** property of the HTMLTableColElement interface is a string indicating how to horizontally align text in a table <col> column element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableColElement/align)
     */
    align: string;
    /**
     * The **`ch`** property of the HTMLTableColElement interface does nothing. It reflects the char attribute of the <col> element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableColElement/ch)
     */
    ch: string;
    /**
     * The **`chOff`** property of the HTMLTableColElement interface does nothing. It reflects the charoff attribute of the <col> element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableColElement/chOff)
     */
    chOff: string;
    /**
     * The **`span`** property of the HTMLTableColElement interface represents the number of columns this <col> or <colgroup> must span; this lets the column occupy space across multiple columns of the table. It reflects the span attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableColElement/span)
     */
    span: number;
    /**
     * The **`vAlign`** property of the HTMLTableColElement interface is a string indicating how to vertically align text in a table <col> column element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableColElement/vAlign)
     */
    vAlign: string;
    /** @deprecated */
    width: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableColElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableColElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTableColElement: {
    prototype: HTMLTableColElement;
    new(): HTMLTableColElement;
};

/** @deprecated prefer HTMLTableCellElement */
interface HTMLTableDataCellElement extends HTMLTableCellElement {
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableDataCellElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableDataCellElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/**
 * The **`HTMLTableElement`** interface provides special properties and methods (beyond the regular HTMLElement object interface it also has available to it by inheritance) for manipulating the layout and presentation of tables in an HTML document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement)
 */
interface HTMLTableElement extends HTMLElement {
    /**
     * The **`HTMLTableElement.align`** property represents the alignment of the table.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/align)
     */
    align: string;
    /**
     * The bgcolor property of the HTMLTableElement represents the background color of the table.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/bgColor)
     */
    bgColor: string;
    /**
     * The **`HTMLTableElement.border`** property represents the border width of the <table> element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/border)
     */
    border: string;
    /**
     * The **`HTMLTableElement.caption`** property represents the table caption. If no caption element is associated with the table, this property is null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/caption)
     */
    caption: HTMLTableCaptionElement | null;
    /**
     * The **`HTMLTableElement.cellPadding`** property represents the padding around the individual cells of the table.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/cellPadding)
     */
    cellPadding: string;
    /**
     * While you should instead use the CSS border-spacing property, the obsolete HTMLTableElement interface's **`cellSpacing`** property represents the spacing around the individual <th> and <td> elements representing a table's cells. Any two cells are separated by the sum of the cellSpacing of each of the two cells.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/cellSpacing)
     */
    cellSpacing: string;
    /**
     * The HTMLTableElement interface's **`frame`** property is a string that indicates which of the table's exterior borders should be drawn.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/frame)
     */
    frame: string;
    /**
     * The read-only HTMLTableElement property **`rows`** returns a live HTMLCollection of all the rows in the table, including the rows contained within any <thead>, <tfoot>, and <tbody> elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/rows)
     */
    readonly rows: HTMLCollectionOf<HTMLTableRowElement>;
    /**
     * The **`HTMLTableElement.rules`** property indicates which cell borders to render in the table.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/rules)
     */
    rules: string;
    /**
     * The **`HTMLTableElement.summary`** property represents the table description.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/summary)
     */
    summary: string;
    /**
     * The **`HTMLTableElement.tBodies`** read-only property returns a live HTMLCollection of the bodies in a <table>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/tBodies)
     */
    readonly tBodies: HTMLCollectionOf<HTMLTableSectionElement>;
    /**
     * The **`HTMLTableElement.tFoot`** property represents the <tfoot> element of a <table>. Its value will be null if there is no such element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/tFoot)
     */
    tFoot: HTMLTableSectionElement | null;
    /**
     * The **`HTMLTableElement.tHead`** represents the <thead> element of a <table>. Its value will be null if there is no such element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/tHead)
     */
    tHead: HTMLTableSectionElement | null;
    /**
     * The **`HTMLTableElement.width`** property represents the desired width of the table.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/width)
     */
    width: string;
    /**
     * The **`HTMLTableElement.createCaption()`** method returns the <caption> element associated with a given <table>. If no <caption> element exists on the table, this method creates it, and then returns it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/createCaption)
     */
    createCaption(): HTMLTableCaptionElement;
    /**
     * The **`createTBody()`** method of HTMLTableElement objects creates and returns a new <tbody> element associated with a given <table>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/createTBody)
     */
    createTBody(): HTMLTableSectionElement;
    /**
     * The **`createTFoot()`** method of HTMLTableElement objects returns the <tfoot> element associated with a given <table>. If no footer exists in the table, this method creates it, and then returns it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/createTFoot)
     */
    createTFoot(): HTMLTableSectionElement;
    /**
     * The **`createTHead()`** method of HTMLTableElement objects returns the <thead> element associated with a given <table>. If no header exists in the table, this method creates it, and then returns it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/createTHead)
     */
    createTHead(): HTMLTableSectionElement;
    /**
     * The **`HTMLTableElement.deleteCaption()`** method removes the <caption> element from a given <table>. If there is no <caption> element associated with the table, this method does nothing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/deleteCaption)
     */
    deleteCaption(): void;
    /**
     * The **`HTMLTableElement.deleteRow()`** method removes a specific row (<tr>) from a given <table>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/deleteRow)
     */
    deleteRow(index: number): void;
    /**
     * The **`HTMLTableElement.deleteTFoot()`** method removes the <tfoot> element from a given <table>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/deleteTFoot)
     */
    deleteTFoot(): void;
    /**
     * The **`HTMLTableElement.deleteTHead()`** removes the <thead> element from a given <table>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/deleteTHead)
     */
    deleteTHead(): void;
    /**
     * The **`insertRow()`** method of the HTMLTableElement interface inserts a new row (<tr>) in a given <table>, and returns a reference to the new row.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableElement/insertRow)
     */
    insertRow(index?: number): HTMLTableRowElement;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTableElement: {
    prototype: HTMLTableElement;
    new(): HTMLTableElement;
};

/** @deprecated prefer HTMLTableCellElement */
interface HTMLTableHeaderCellElement extends HTMLTableCellElement {
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableHeaderCellElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableHeaderCellElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/**
 * The **`HTMLTableRowElement`** interface provides special properties and methods (beyond the HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of rows in an HTML table.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement)
 */
interface HTMLTableRowElement extends HTMLElement {
    /**
     * The **`align`** property of the HTMLTableRowElement interface is a string indicating how to horizontally align text in the <tr> table row. Individual cells can override it.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/align)
     */
    align: string;
    /**
     * The **`HTMLTableRowElement.bgColor`** property is used to set the background color of a row or retrieve the value of the obsolete bgColor attribute, if present.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/bgColor)
     */
    bgColor: string;
    /**
     * The **`cells`** read-only property of the HTMLTableRowElement interface returns a live HTMLCollection containing the cells in the row. The HTMLCollection is live and is automatically updated when cells are added or removed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/cells)
     */
    readonly cells: HTMLCollectionOf<HTMLTableCellElement>;
    /**
     * The **`ch`** property of the HTMLTableRowElement interface does nothing. It reflects the char attribute of the <tr> element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/ch)
     */
    ch: string;
    /**
     * The **`chOff`** property of the HTMLTableRowElement interface does nothing. It reflects the charoff attribute of the <tr> element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/chOff)
     */
    chOff: string;
    /**
     * The **`rowIndex`** read-only property of the HTMLTableRowElement interface represents the position of a row within the whole <table>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/rowIndex)
     */
    readonly rowIndex: number;
    /**
     * The **`sectionRowIndex`** read-only property of the HTMLTableRowElement interface represents the position of a row within the current section (<thead>, <tbody>, or <tfoot>).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/sectionRowIndex)
     */
    readonly sectionRowIndex: number;
    /**
     * The **`vAlign`** property of the HTMLTableRowElement interface is a string indicating how to vertically align text in a <tr> table row. Individual cells can override it.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/vAlign)
     */
    vAlign: string;
    /**
     * The **`deleteCell()`** method of the HTMLTableRowElement interface removes a specific row cell from a given <tr>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/deleteCell)
     */
    deleteCell(index: number): void;
    /**
     * The **`insertCell()`** method of the HTMLTableRowElement interface inserts a new cell (<td>) into a table row (<tr>) and returns a reference to the cell.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableRowElement/insertCell)
     */
    insertCell(index?: number): HTMLTableCellElement;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableRowElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableRowElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTableRowElement: {
    prototype: HTMLTableRowElement;
    new(): HTMLTableRowElement;
};

/**
 * The **`HTMLTableSectionElement`** interface provides special properties and methods (beyond the HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of sections, that is headers, footers and bodies (<thead>, <tfoot>, and <tbody>, respectively) in an HTML table.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement)
 */
interface HTMLTableSectionElement extends HTMLElement {
    /**
     * The **`align`** property of the HTMLTableSectionElement interface is a string indicating how to horizontally align text in a <thead>, <tbody> or <tfoot> table section. Individual rows and cells can override it.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/align)
     */
    align: string;
    /**
     * The **`ch`** property of the HTMLTableSectionElement interface does nothing. It reflects the char attribute of the section element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/ch)
     */
    ch: string;
    /**
     * The **`chOff`** property of the HTMLTableSectionElement interface does nothing. It reflects the charoff attribute of the section element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/chOff)
     */
    chOff: string;
    /**
     * The **`rows`** read-only property of the HTMLTableSectionElement interface returns a live HTMLCollection containing the rows in the section. The HTMLCollection is live and is automatically updated when rows are added or removed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/rows)
     */
    readonly rows: HTMLCollectionOf<HTMLTableRowElement>;
    /**
     * The **`vAlign`** property of the HTMLTableSectionElement interface is a string indicating how to vertically align text in a <thead>, <tbody> or <tfoot> table section. Individual rows and cells can override it.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/vAlign)
     */
    vAlign: string;
    /**
     * The **`deleteRow()`** method of the HTMLTableSectionElement interface removes a specific row (<tr>) from a given <section>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/deleteRow)
     */
    deleteRow(index: number): void;
    /**
     * The **`insertRow()`** method of the HTMLTableSectionElement interface inserts a new row (<tr>) in the given table sectioning element (<thead>, <tfoot>, or <tbody>), then returns a reference to this new row.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTableSectionElement/insertRow)
     */
    insertRow(index?: number): HTMLTableRowElement;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableSectionElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTableSectionElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTableSectionElement: {
    prototype: HTMLTableSectionElement;
    new(): HTMLTableSectionElement;
};

/**
 * The **`HTMLTemplateElement`** interface enables access to the contents of an HTML <template> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTemplateElement)
 */
interface HTMLTemplateElement extends HTMLElement {
    /**
     * The **`content`** property of the HTMLTemplateElement interface returns the <template> element's template contents as a DocumentFragment. This content's ownerDocument is a separate Document from the one that contains the <template> element itself — unless the containing document is itself constructed for the purpose of holding template content.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTemplateElement/content)
     */
    readonly content: DocumentFragment;
    /**
     * The **`shadowRootClonable`** property reflects the value of the shadowrootclonable attribute of the associated <template> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTemplateElement/shadowRootClonable)
     */
    shadowRootClonable: boolean;
    shadowRootCustomElementRegistry: string;
    /**
     * The **`shadowRootDelegatesFocus`** property of the HTMLTemplateElement interface reflects the value of the shadowrootdelegatesfocus attribute of the associated <template> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTemplateElement/shadowRootDelegatesFocus)
     */
    shadowRootDelegatesFocus: boolean;
    /**
     * The **`shadowRootMode`** property of the HTMLTemplateElement interface reflects the value of the shadowrootmode attribute of the associated <template> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTemplateElement/shadowRootMode)
     */
    shadowRootMode: string;
    /**
     * The **`shadowRootSerializable`** property reflects the value of the shadowrootserializable attribute of the associated <template> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTemplateElement/shadowRootSerializable)
     */
    shadowRootSerializable: boolean;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTemplateElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTemplateElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTemplateElement: {
    prototype: HTMLTemplateElement;
    new(): HTMLTemplateElement;
};

/**
 * The **`HTMLTextAreaElement`** interface provides properties and methods for manipulating the layout and presentation of <textarea> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement)
 */
interface HTMLTextAreaElement extends HTMLElement {
    /**
     * The **`autocomplete`** property of the HTMLTextAreaElement interface indicates whether the value of the control can be automatically completed by the browser. It reflects the <textarea> element's autocomplete attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/autocomplete)
     */
    autocomplete: AutoFill;
    /**
     * The **`cols`** property of the HTMLTextAreaElement interface is a positive integer representing the visible width of the multi-line text control, in average character widths. It reflects the <textarea> element's cols attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/cols)
     */
    cols: number;
    /**
     * The **`defaultValue`** property of the HTMLTextAreaElement interface represents the default text content of this text area. Getting and setting this value is equivalent to getting and setting textContent on the <textarea>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/defaultValue)
     */
    defaultValue: string;
    /**
     * The **`dirName`** property of the HTMLTextAreaElement interface is the directionality of the element. It reflects the value of the <textarea> element's dirName attribute. This property can be retrieved or set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/dirName)
     */
    dirName: string;
    /**
     * The **`disabled`** property of the HTMLTextAreaElement interface indicates whether this multi-line text control is disabled and cannot be interacted with. It reflects the <textarea> element's disabled attribute. When false, this textarea may still be disabled if its containing element, such as a <fieldset>, is disabled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`form`** read-only property of the HTMLTextAreaElement interface returns an HTMLFormElement object that owns this <textarea>, or null if this textarea is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`HTMLTextAreaElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <textArea> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement>;
    /**
     * The **`maxLength`** property of the HTMLTextAreaElement interface indicates the maximum number of characters (in UTF-16 code units) allowed to be entered for the value of the <textarea> element, and the maximum number of characters allowed for the value to be valid. It reflects the element's maxlength attribute. -1 means there is no limit on the length of the value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/maxLength)
     */
    maxLength: number;
    /**
     * The **`minLength`** property of the HTMLTextAreaElement interface indicates the minimum number of characters (in UTF-16 code units) required for the value of the <textarea> element to be valid. It reflects the element's minlength attribute. -1 means there is no minimum length requirement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/minLength)
     */
    minLength: number;
    /**
     * The **`name`** property of the HTMLTextAreaElement interface indicates the name of the <textarea> element. It reflects the element's name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/name)
     */
    name: string;
    /**
     * The **`placeholder`** property of the HTMLTextAreaElement interface represents a hint to the user of what can be entered in the control. It reflects the <textarea> element's placeholder attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/placeholder)
     */
    placeholder: string;
    /**
     * The **`readOnly`** property of the HTMLTextAreaElement interface indicates that the user cannot modify the value of the control. Unlike the disabled attribute, the readonly attribute does not prevent the user from clicking or selecting in the control. It reflects the <textarea> element's readonly attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/readOnly)
     */
    readOnly: boolean;
    /**
     * The **`required`** property of the HTMLTextAreaElement interface specifies that the user must fill in a value before submitting a form. It reflects the <textarea> element's required attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/required)
     */
    required: boolean;
    /**
     * The **`rows`** property of the HTMLTextAreaElement interface is a positive integer representing the visible text lines of the text control. It reflects the <textarea> element's rows attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/rows)
     */
    rows: number;
    /**
     * The **`selectionDirection`** property of the HTMLTextAreaElement interface specifies the current direction of the selection. The possible values are "forward", "backward", and "none". The forward value indicates the selection was performed in the start-to-end direction of the current locale, with backward indicating the opposite direction. The none value occurs if the direction is unknown. It can be used to both retrieve and change the direction of the <textarea>s selected text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/selectionDirection)
     */
    selectionDirection: SelectionDirection;
    /**
     * The **`selectionEnd`** property of the HTMLTextAreaElement interface specifies the end position of the current text selection in a <textarea> element. It is a number representing the last index of the selected text. It can be used to both retrieve and set the index of the end of a <textarea>s selected text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/selectionEnd)
     */
    selectionEnd: number;
    /**
     * The **`selectionStart`** property of the HTMLTextAreaElement interface specifies the start position of the current text selection in a <textarea> element. It is a number representing the beginning index of the selected text. It can be used to both retrieve and set the start of the index of the beginning of a <textarea>s selected text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/selectionStart)
     */
    selectionStart: number;
    /**
     * The **`textLength`** read-only property of the HTMLTextAreaElement interface is a non-negative integer representing the number of characters, in UTF-16 code units, of the <textarea> element's value. It is a shortcut of accessing length on its value property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/textLength)
     */
    readonly textLength: number;
    /**
     * The **`type`** read-only property of the HTMLTextAreaElement interface returns the string "textarea".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/type)
     */
    readonly type: string;
    /**
     * The **`validationMessage`** read-only property of the HTMLTextAreaElement interface returns a string representing a localized message that describes the validation constraints that the <textarea> control does not satisfy (if any). This is the empty string if the control is not a candidate for constraint validation (HTMLTextAreaElement.willValidate is false), or it satisfies its constraints.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLTextAreaElement interface returns a ValidityState object that represents the validity states this element is in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`value`** property of the HTMLTextAreaElement interface represents the value of the <textarea> element as a string, which is an empty string if the widget contains no content. It returns or sets the raw value contained in the control.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/value)
     */
    value: string;
    /**
     * The **`willValidate`** read-only property of the HTMLTextAreaElement interface indicates whether the <textarea> element is a candidate for constraint validation. It is false if any conditions bar it from constraint validation, such as when its disabled or readOnly property is true.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`wrap`** property of the HTMLTextAreaElement interface indicates how the control should wrap the value for form submission. It reflects the <textarea> element's wrap attribute. Note that the "hard" value only has an effect when the cols attribute is also set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/wrap)
     */
    wrap: string;
    /**
     * The **`checkValidity()`** method of the HTMLTextAreaElement interface returns a boolean value which indicates if the element meets any constraint validation rules applied to it. If false, the method also fires an invalid event on the element. Because there's no default browser behavior for checkValidity(), canceling this invalid event has no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the HTMLTextAreaElement interface performs the same validity checking steps as the checkValidity() method. In addition, if the invalid event is not canceled, the browser displays the problem to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`select()`** method of the HTMLTextAreaElement interface selects the entire contents of the <textarea> element. In addition, the select event is fired. The select() method does not take any parameters and does not return a value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/select)
     */
    select(): void;
    /**
     * The **`setCustomValidity()`** method of the HTMLTextAreaElement interface sets the custom validity message for the <textarea> element. Use the empty string to indicate that the element does not have a custom validity error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    /**
     * The **`setRangeText()`** method of the HTMLTextAreaElement interface replaces a range of text in a <textarea> element with new text passed as the argument.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/setRangeText)
     */
    setRangeText(replacement: string): void;
    setRangeText(replacement: string, start: number, end: number, selectionMode?: SelectionMode): void;
    /**
     * The **`setSelectionRange()`** method of the HTMLTextAreaElement interface sets the start and end positions of the current text selection, and optionally the direction, in a <textarea> element. This updates the selection state immediately, though the visual highlight only appears when the element is focused. The direction indicates the in which selection should be considered to have occurred; for example, that the selection was set by the user clicking and dragging from the end of the selected text toward the beginning. In addition, the select and selectionchange events are fired.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTextAreaElement/setSelectionRange)
     */
    setSelectionRange(start: number | null, end: number | null, direction?: SelectionDirection): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTextAreaElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTextAreaElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTextAreaElement: {
    prototype: HTMLTextAreaElement;
    new(): HTMLTextAreaElement;
};

/**
 * The **`HTMLTimeElement`** interface provides special properties (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating <time> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTimeElement)
 */
interface HTMLTimeElement extends HTMLElement {
    /**
     * The **`dateTime`** property of the HTMLTimeElement interface is a string that reflects the datetime HTML attribute, containing a machine-readable form of the element's date and time value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTimeElement/dateTime)
     */
    dateTime: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTimeElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTimeElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTimeElement: {
    prototype: HTMLTimeElement;
    new(): HTMLTimeElement;
};

/**
 * The **`HTMLTitleElement`** interface is implemented by a document's <title>. This element inherits all of the properties and methods of the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTitleElement)
 */
interface HTMLTitleElement extends HTMLElement {
    /**
     * The **`text`** property of the HTMLTitleElement interface represents the child text content of the document's title as a string. It contains the <title> element's content as text; if HTML tags are included within the <title> element, they are included as part of the string value rather than being parsed as HTML.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTitleElement/text)
     */
    text: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTitleElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTitleElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTitleElement: {
    prototype: HTMLTitleElement;
    new(): HTMLTitleElement;
};

/**
 * The **`HTMLTrackElement`** interface represents an HTML <track> element within the DOM. This element can be used as a child of either <audio> or <video> to specify a text track containing information such as closed captions or subtitles.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement)
 */
interface HTMLTrackElement extends HTMLElement {
    /**
     * The **`default`** property of the HTMLTrackElement interface represents whether the track will be enabled if the user's preferences do not indicate that another track would be more appropriate. It reflects the <track> element's boolean default attribute, returning true if present and false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/default)
     */
    default: boolean;
    /**
     * The **`kind`** property of the HTMLTrackElement interface represents the type of track, or how the text track is meant to be used. It reflects the <track> element's enumerated kind attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/kind)
     */
    kind: string;
    /**
     * The **`label`** property of the HTMLTrackElement represents the user-readable title displayed when listing subtitle, caption, and audio descriptions for a track. It reflects the <track> element's label attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/label)
     */
    label: string;
    /**
     * The **`readyState`** read-only property of the HTMLTrackElement interface returns a number representing the <track> element's text track readiness state:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/readyState)
     */
    readonly readyState: number;
    /**
     * The **`src`** property of the HTMLTrackElement interface reflects the value of the <track> element's src attribute, which indicates the URL of the text track's data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/src)
     */
    src: string;
    /**
     * The **`srclang`** property of the HTMLTrackElement interface reflects the value of the <track> element's srclang attribute or the empty string if not defined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/srclang)
     */
    srclang: string;
    /**
     * The **`track`** read-only property of the HTMLTrackElement interface returns a TextTrack object corresponding to the text track of the <track> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/track)
     */
    readonly track: TextTrack;
    readonly NONE: 0;
    readonly LOADING: 1;
    readonly LOADED: 2;
    readonly ERROR: 3;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTrackElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLTrackElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLTrackElement: {
    prototype: HTMLTrackElement;
    new(): HTMLTrackElement;
    readonly NONE: 0;
    readonly LOADING: 1;
    readonly LOADED: 2;
    readonly ERROR: 3;
};

/**
 * The **`HTMLUListElement`** interface provides special properties (beyond those defined on the regular HTMLElement interface it also has available to it by inheritance) for manipulating unordered list (<ul>) elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLUListElement)
 */
interface HTMLUListElement extends HTMLElement {
    /**
     * The **`compact`** property of the HTMLUListElement interface indicates that spacing between list items should be reduced. The exact handling of the compact attribute is browser-specific. Instead of using this property, consider using CSS line-height instead.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLUListElement/compact)
     */
    compact: boolean;
    /** @deprecated */
    type: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLUListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLUListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLUListElement: {
    prototype: HTMLUListElement;
    new(): HTMLUListElement;
};

/**
 * The **`HTMLUnknownElement`** interface represents an invalid HTML element and derives from the HTMLElement interface, but without implementing any additional properties or methods.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLUnknownElement)
 */
interface HTMLUnknownElement extends HTMLElement {
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLUnknownElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLUnknownElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLUnknownElement: {
    prototype: HTMLUnknownElement;
    new(): HTMLUnknownElement;
};

interface HTMLVideoElementEventMap extends HTMLMediaElementEventMap {
    "enterpictureinpicture": PictureInPictureEvent;
    "leavepictureinpicture": PictureInPictureEvent;
}

/**
 * Implemented by the <video> element, the **`HTMLVideoElement`** interface provides special properties and methods for manipulating video objects. It also inherits properties and methods of HTMLMediaElement and HTMLElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement)
 */
interface HTMLVideoElement extends HTMLMediaElement {
    /**
     * The HTMLVideoElement **`disablePictureInPicture`** property reflects the HTML attribute indicating whether the picture-in-picture feature is disabled for the current element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/disablePictureInPicture)
     */
    disablePictureInPicture: boolean;
    /**
     * The **`height`** property of the HTMLVideoElement interface returns an integer that reflects the height attribute of the <video> element, specifying the displayed height of the resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/height)
     */
    height: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/enterpictureinpicture_event) */
    onenterpictureinpicture: ((this: HTMLVideoElement, ev: PictureInPictureEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/leavepictureinpicture_event) */
    onleavepictureinpicture: ((this: HTMLVideoElement, ev: PictureInPictureEvent) => any) | null;
    playsInline: boolean;
    /**
     * The **`poster`** property of the HTMLVideoElement interface is a string that reflects the URL for an image to be shown while no video data is available. If the property does not represent a valid URL, no poster frame will be shown.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/poster)
     */
    poster: string;
    /**
     * The HTMLVideoElement interface's read-only **`videoHeight`** property indicates the intrinsic height of the video, expressed in CSS pixels. In simple terms, this is the height of the media in its natural size.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/videoHeight)
     */
    readonly videoHeight: number;
    /**
     * The HTMLVideoElement interface's read-only **`videoWidth`** property indicates the intrinsic width of the video, expressed in CSS pixels. In simple terms, this is the width of the media in its natural size.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/videoWidth)
     */
    readonly videoWidth: number;
    /**
     * The **`width`** property of the HTMLVideoElement interface returns an integer that reflects the width attribute of the <video> element, specifying the displayed width of the resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/width)
     */
    width: number;
    /**
     * The **`cancelVideoFrameCallback()`** method of the HTMLVideoElement interface cancels a previously-registered video frame callback.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/cancelVideoFrameCallback)
     */
    cancelVideoFrameCallback(handle: number): void;
    /**
     * The HTMLVideoElement method **`getVideoPlaybackQuality()`** creates and returns a VideoPlaybackQuality object containing metrics including how many frames have been lost.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/getVideoPlaybackQuality)
     */
    getVideoPlaybackQuality(): VideoPlaybackQuality;
    /**
     * The HTMLVideoElement method **`requestPictureInPicture()`** issues an asynchronous request to display the video in picture-in-picture mode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/requestPictureInPicture)
     */
    requestPictureInPicture(): Promise<PictureInPictureWindow>;
    /**
     * The **`requestVideoFrameCallback()`** method of the HTMLVideoElement interface registers a callback function that runs when a new video frame is sent to the compositor. This enables developers to perform efficient operations on each video frame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback)
     */
    requestVideoFrameCallback(callback: VideoFrameRequestCallback): number;
    addEventListener<K extends keyof HTMLVideoElementEventMap>(type: K, listener: (this: HTMLVideoElement, ev: HTMLVideoElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLVideoElementEventMap>(type: K, listener: (this: HTMLVideoElement, ev: HTMLVideoElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLVideoElement: {
    prototype: HTMLVideoElement;
    new(): HTMLVideoElement;
};

/**
 * The **`HashChangeEvent`** interface represents events that fire when the fragment identifier of the URL has changed.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HashChangeEvent)
 */
interface HashChangeEvent extends Event {
    /**
     * The **`newURL`** read-only property of the HashChangeEvent interface returns the new URL to which the window is navigating.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HashChangeEvent/newURL)
     */
    readonly newURL: string;
    /**
     * The **`oldURL`** read-only property of the HashChangeEvent interface returns the previous URL from which the window was navigated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HashChangeEvent/oldURL)
     */
    readonly oldURL: string;
}

declare var HashChangeEvent: {
    prototype: HashChangeEvent;
    new(type: string, eventInitDict?: HashChangeEventInit): HashChangeEvent;
};

/**
 * The **`Headers`** interface of the Fetch API allows you to perform various actions on HTTP request and response headers. These actions include retrieving, setting, adding to, and removing headers from the list of the request's headers.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers)
 */
interface Headers {
    /**
     * The **`append()`** method of the Headers interface appends a new value onto an existing header inside a Headers object, or adds the header if it does not already exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers/append)
     */
    append(name: string, value: string): void;
    /**
     * The **`delete()`** method of the Headers interface deletes a header from the current Headers object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers/delete)
     */
    delete(name: string): void;
    /**
     * The **`get()`** method of the Headers interface returns a byte string of all the values of a header within a Headers object with a given name. If the requested header doesn't exist in the Headers object, it returns null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers/get)
     */
    get(name: string): string | null;
    /**
     * The **`getSetCookie()`** method of the Headers interface returns an array containing the values of all Set-Cookie headers associated with a response. This allows Headers objects to handle having multiple Set-Cookie headers, which wasn't possible prior to its implementation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers/getSetCookie)
     */
    getSetCookie(): string[];
    /**
     * The **`has()`** method of the Headers interface returns a boolean stating whether a Headers object contains a certain header.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers/has)
     */
    has(name: string): boolean;
    /**
     * The **`set()`** method of the Headers interface sets a new value for an existing header inside a Headers object, or adds the header if it does not already exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Headers/set)
     */
    set(name: string, value: string): void;
    forEach(callbackfn: (value: string, key: string, parent: Headers) => void, thisArg?: any): void;
}

declare var Headers: {
    prototype: Headers;
    new(init?: HeadersInit): Headers;
};

/**
 * The **`Highlight`** interface of the CSS Custom Highlight API is used to represent a collection of Range instances to be styled using the API.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Highlight)
 */
interface Highlight {
    /**
     * The **`priority`** property of the Highlight interface is a number used to determine which highlight's styles should be used to resolve style conflicts in overlapping parts. Highlights with a higher priority number have preference over those with a lower priority.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Highlight/priority)
     */
    priority: number;
    /**
     * The **`type`** property of the Highlight interface is an enumerated String used to specify the meaning of the highlight. This allows assistive technologies, such as screen readers, to include this meaning when exposing the highlight to users.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Highlight/type)
     */
    type: HighlightType;
    forEach(callbackfn: (value: AbstractRange, key: AbstractRange, parent: Highlight) => void, thisArg?: any): void;
}

declare var Highlight: {
    prototype: Highlight;
    new(...initialRanges: AbstractRange[]): Highlight;
};

/**
 * The **`HighlightRegistry`** interface of the CSS Custom Highlight API is used to register Highlight objects to be styled using the API. It is accessed via CSS.highlights.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HighlightRegistry)
 */
interface HighlightRegistry {
    forEach(callbackfn: (value: Highlight, key: string, parent: HighlightRegistry) => void, thisArg?: any): void;
}

declare var HighlightRegistry: {
    prototype: HighlightRegistry;
    new(): HighlightRegistry;
};

/**
 * The **`History`** interface of the History API allows manipulation of the browser session history, that is the pages visited in the tab or frame that the current page is loaded in.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History)
 */
interface History {
    /**
     * The **`length`** read-only property of the History interface returns an integer representing the number of entries in the session history, including the currently loaded page.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/length)
     */
    readonly length: number;
    /**
     * The **`scrollRestoration`** property of the History interface allows web applications to explicitly set default scroll restoration behavior on history navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/scrollRestoration)
     */
    scrollRestoration: ScrollRestoration;
    /**
     * The **`state`** read-only property of the History interface returns a value representing the state at the top of the history stack. This is a way to look at the state without having to wait for a popstate event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/state)
     */
    readonly state: any;
    /**
     * The **`back()`** method of the History interface causes the browser to move back one page in the session history.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/back)
     */
    back(): void;
    /**
     * The **`forward()`** method of the History interface causes the browser to move forward one page in the session history. It has the same effect as calling history.go(1).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/forward)
     */
    forward(): void;
    /**
     * The **`go()`** method of the History interface loads a specific page from the session history. You can use it to move forwards and backwards through the history depending on the value of a parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/go)
     */
    go(delta?: number): void;
    /**
     * The **`pushState()`** method of the History interface adds an entry to the browser's session history stack.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/pushState)
     */
    pushState(data: any, unused: string, url?: string | URL | null): void;
    /**
     * The **`replaceState()`** method of the History interface modifies the current history entry, replacing it with the state object and URL passed in the method parameters. This method is particularly useful when you want to update the state object or URL of the current history entry in response to some user action.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/History/replaceState)
     */
    replaceState(data: any, unused: string, url?: string | URL | null): void;
}

declare var History: {
    prototype: History;
    new(): History;
};

/**
 * The **`IDBCursor`** interface of the IndexedDB API represents a cursor for traversing or iterating over multiple records in a database.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor)
 */
interface IDBCursor {
    /**
     * The **`direction`** read-only property of the IDBCursor interface is a string that returns the direction of traversal of the cursor (set using IDBObjectStore.openCursor for example). See the Value section below for possible values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/direction)
     */
    readonly direction: IDBCursorDirection;
    /**
     * The **`key`** read-only property of the IDBCursor interface returns the key for the record at the cursor's position. If the cursor is outside its range, this is set to undefined. The cursor's key can be any data type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/key)
     */
    readonly key: IDBValidKey;
    /**
     * The **`primaryKey`** read-only property of the IDBCursor interface returns the cursor's current effective key. If the cursor is currently being iterated or has iterated outside its range, this is set to undefined. The cursor's primary key can be any data type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/primaryKey)
     */
    readonly primaryKey: IDBValidKey;
    /**
     * The **`request`** read-only property of the IDBCursor interface returns the IDBRequest used to obtain the cursor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/request)
     */
    readonly request: IDBRequest;
    /**
     * The **`source`** read-only property of the IDBCursor interface returns the IDBObjectStore or IDBIndex that the cursor is iterating over. This function never returns null or throws an exception, even if the cursor is currently being iterated, has iterated past its end, or its transaction is not active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/source)
     */
    readonly source: IDBObjectStore | IDBIndex;
    /**
     * The **`advance()`** method of the IDBCursor interface sets the number of times a cursor should move its position forward.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/advance)
     */
    advance(count: number): void;
    /**
     * The **`continue()`** method of the IDBCursor interface advances the cursor to the next position along its direction, to the item whose key matches the optional key parameter. If no key is specified, the cursor advances to the immediate next position, based on its direction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/continue)
     */
    continue(key?: IDBValidKey): void;
    /**
     * The **`continuePrimaryKey()`** method of the IDBCursor interface advances the cursor to the item whose key matches the key parameter as well as whose primary key matches the primary key parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/continuePrimaryKey)
     */
    continuePrimaryKey(key: IDBValidKey, primaryKey: IDBValidKey): void;
    /**
     * The **`delete()`** method of the IDBCursor interface returns an IDBRequest object, and, in a separate thread, deletes the record at the cursor's position, without changing the cursor's position. Once the record is deleted, the cursor's value is set to null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/delete)
     */
    delete(): IDBRequest<undefined>;
    /**
     * The **`update()`** method of the IDBCursor interface returns an IDBRequest object, and, in a separate thread, updates the value at the current position of the cursor in the object store. If the cursor points to a record that has just been deleted, a new record is created.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursor/update)
     */
    update(value: any): IDBRequest<IDBValidKey>;
}

declare var IDBCursor: {
    prototype: IDBCursor;
    new(): IDBCursor;
};

/**
 * The **`IDBCursorWithValue`** interface of the IndexedDB API represents a cursor for traversing or iterating over multiple records in a database. It is the same as the IDBCursor, except that it includes the value property.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursorWithValue)
 */
interface IDBCursorWithValue extends IDBCursor {
    /**
     * The **`value`** read-only property of the IDBCursorWithValue interface returns the value of the current cursor, whatever that is.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBCursorWithValue/value)
     */
    readonly value: any;
}

declare var IDBCursorWithValue: {
    prototype: IDBCursorWithValue;
    new(): IDBCursorWithValue;
};

interface IDBDatabaseEventMap {
    "abort": Event;
    "close": Event;
    "error": Event;
    "versionchange": IDBVersionChangeEvent;
}

/**
 * The **`IDBDatabase`** interface of the IndexedDB API provides a connection to a database; you can use an IDBDatabase object to open a transaction on your database then create, manipulate, and delete objects (data) in that database. The interface provides the only way to get and manage versions of the database.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase)
 */
interface IDBDatabase extends EventTarget {
    /**
     * The **`name`** read-only property of the IDBDatabase interface is a string that contains the name of the connected database.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/name)
     */
    readonly name: string;
    /**
     * The **`objectStoreNames`** read-only property of the IDBDatabase interface is a DOMStringList containing a list of the names of the object stores currently in the connected database.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/objectStoreNames)
     */
    readonly objectStoreNames: DOMStringList;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/abort_event) */
    onabort: ((this: IDBDatabase, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/close_event) */
    onclose: ((this: IDBDatabase, ev: Event) => any) | null;
    onerror: ((this: IDBDatabase, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/versionchange_event) */
    onversionchange: ((this: IDBDatabase, ev: IDBVersionChangeEvent) => any) | null;
    /**
     * The **`version`** property of the IDBDatabase interface is a 64-bit integer that contains the version of the connected database. When a database is first created, this attribute is an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/version)
     */
    readonly version: number;
    /**
     * The **`close()`** method of the IDBDatabase interface returns immediately and closes the connection in a separate thread.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/close)
     */
    close(): void;
    /**
     * The **`createObjectStore()`** method of the IDBDatabase interface creates and returns a new IDBObjectStore.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/createObjectStore)
     */
    createObjectStore(name: string, options?: IDBObjectStoreParameters): IDBObjectStore;
    /**
     * The **`deleteObjectStore()`** method of the IDBDatabase interface destroys the object store with the given name in the connected database, along with any indexes that reference it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/deleteObjectStore)
     */
    deleteObjectStore(name: string): void;
    /**
     * The **`transaction`** method of the IDBDatabase interface immediately returns a transaction object (IDBTransaction) containing the IDBTransaction.objectStore method, which you can use to access your object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBDatabase/transaction)
     */
    transaction(storeNames: string | string[], mode?: IDBTransactionMode, options?: IDBTransactionOptions): IDBTransaction;
    addEventListener<K extends keyof IDBDatabaseEventMap>(type: K, listener: (this: IDBDatabase, ev: IDBDatabaseEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof IDBDatabaseEventMap>(type: K, listener: (this: IDBDatabase, ev: IDBDatabaseEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var IDBDatabase: {
    prototype: IDBDatabase;
    new(): IDBDatabase;
};

/**
 * The **`IDBFactory`** interface of the IndexedDB API lets applications asynchronously access the indexed databases. The object that implements the interface is window.indexedDB. You open — that is, create and access — and delete a database with this object, and not directly with IDBFactory.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBFactory)
 */
interface IDBFactory {
    /**
     * The **`cmp()`** method of the IDBFactory interface compares two values as keys to determine equality and ordering for IndexedDB operations, such as storing and iterating.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBFactory/cmp)
     */
    cmp(first: any, second: any): number;
    /**
     * The **`databases`** method of the IDBFactory interface returns a Promise that fulfills with an array of objects containing the name and version of all the available databases.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBFactory/databases)
     */
    databases(): Promise<IDBDatabaseInfo[]>;
    /**
     * The **`deleteDatabase()`** method of the IDBFactory interface requests the deletion of a database. The method returns an IDBOpenDBRequest object immediately, and performs the deletion operation asynchronously.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBFactory/deleteDatabase)
     */
    deleteDatabase(name: string): IDBOpenDBRequest;
    /**
     * The **`open()`** method of the IDBFactory interface requests opening a connection to a database.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBFactory/open)
     */
    open(name: string, version?: number): IDBOpenDBRequest;
}

declare var IDBFactory: {
    prototype: IDBFactory;
    new(): IDBFactory;
};

/**
 * **`IDBIndex`** interface of the IndexedDB API provides asynchronous access to an index in a database. An index is a kind of object store for looking up records in another object store, called the referenced object store. You use this interface to retrieve data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex)
 */
interface IDBIndex {
    /**
     * The **`keyPath`** property of the IDBIndex interface returns the key path of the current index. If null, this index is not auto-populated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/keyPath)
     */
    readonly keyPath: string | string[];
    /**
     * The **`multiEntry`** read-only property of the IDBIndex interface returns a boolean value that affects how the index behaves when the result of evaluating the index's key path yields an array.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/multiEntry)
     */
    readonly multiEntry: boolean;
    /**
     * The **`name`** property of the IDBIndex interface contains a string which names the index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/name)
     */
    name: string;
    /**
     * The **`objectStore`** property of the IDBIndex interface returns the object store referenced by the current index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/objectStore)
     */
    readonly objectStore: IDBObjectStore;
    /**
     * The **`unique`** read-only property returns a boolean that states whether the index allows duplicate keys.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/unique)
     */
    readonly unique: boolean;
    /**
     * The **`count()`** method of the IDBIndex interface returns an IDBRequest object, and in a separate thread, returns the number of records within a key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/count)
     */
    count(query?: IDBValidKey | IDBKeyRange): IDBRequest<number>;
    /**
     * The **`get()`** method of the IDBIndex interface returns an IDBRequest object, and, in a separate thread, finds either the value in the referenced object store that corresponds to the given key or the first corresponding value, if key is set to an IDBKeyRange.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/get)
     */
    get(query: IDBValidKey | IDBKeyRange): IDBRequest<any>;
    /**
     * The **`getAll()`** method of the IDBIndex interface retrieves all objects that are inside the index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/getAll)
     */
    getAll(queryOrOptions?: IDBValidKey | IDBKeyRange | null, count?: number): IDBRequest<any[]>;
    /**
     * The **`getAllKeys()`** method of the IDBIndex interface asynchronously retrieves the primary keys of all objects inside the index, setting them as the result of the request object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/getAllKeys)
     */
    getAllKeys(queryOrOptions?: IDBValidKey | IDBKeyRange | null, count?: number): IDBRequest<IDBValidKey[]>;
    /**
     * The **`getKey()`** method of the IDBIndex interface returns an IDBRequest object, and, in a separate thread, finds either the primary key that corresponds to the given key in this index or the first corresponding primary key, if key is set to an IDBKeyRange.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/getKey)
     */
    getKey(query: IDBValidKey | IDBKeyRange): IDBRequest<IDBValidKey | undefined>;
    /**
     * The **`openCursor()`** method of the IDBIndex interface returns an IDBRequest object, and, in a separate thread, creates a cursor over the specified key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/openCursor)
     */
    openCursor(query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection): IDBRequest<IDBCursorWithValue | null>;
    /**
     * The **`openKeyCursor()`** method of the IDBIndex interface returns an IDBRequest object, and, in a separate thread, creates a cursor over the specified key range, as arranged by this index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBIndex/openKeyCursor)
     */
    openKeyCursor(query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection): IDBRequest<IDBCursor | null>;
}

declare var IDBIndex: {
    prototype: IDBIndex;
    new(): IDBIndex;
};

/**
 * The **`IDBKeyRange`** interface of the IndexedDB API represents a continuous interval over some data type that is used for keys. Records can be retrieved from IDBObjectStore and IDBIndex objects using keys or a range of keys. You can limit the range using lower and upper bounds. For example, you can iterate over all values of a key in the value range A–Z.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange)
 */
interface IDBKeyRange {
    /**
     * The **`lower`** read-only property of the IDBKeyRange interface returns the lower bound of the key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/lower)
     */
    readonly lower: any;
    /**
     * The **`lowerOpen`** read-only property of the IDBKeyRange interface returns a boolean indicating whether the lower-bound value is included in the key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/lowerOpen)
     */
    readonly lowerOpen: boolean;
    /**
     * The **`upper`** read-only property of the IDBKeyRange interface returns the upper bound of the key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/upper)
     */
    readonly upper: any;
    /**
     * The **`upperOpen`** read-only property of the IDBKeyRange interface returns a boolean indicating whether the upper-bound value is included in the key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/upperOpen)
     */
    readonly upperOpen: boolean;
    /**
     * The **`includes()`** method of the IDBKeyRange interface returns a boolean indicating whether a specified key is inside the key range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/includes)
     */
    includes(key: any): boolean;
}

declare var IDBKeyRange: {
    prototype: IDBKeyRange;
    new(): IDBKeyRange;
    /**
     * The **`bound()`** static method of the IDBKeyRange interface creates a new key range with the specified upper and lower bounds. The bounds can be open (that is, the bounds exclude the endpoint values) or closed (that is, the bounds include the endpoint values). By default, the bounds are closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/bound_static)
     */
    bound(lower: any, upper: any, lowerOpen?: boolean, upperOpen?: boolean): IDBKeyRange;
    /**
     * The **`lowerBound()`** static method of the IDBKeyRange interface creates a new key range with only a lower bound. By default, it includes the lower endpoint value and is closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/lowerBound_static)
     */
    lowerBound(lower: any, open?: boolean): IDBKeyRange;
    /**
     * The **`only()`** static method of the IDBKeyRange interface creates a new key range containing a single value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/only_static)
     */
    only(value: any): IDBKeyRange;
    /**
     * The **`upperBound()`** static method of the IDBKeyRange interface creates a new upper-bound key range. By default, it includes the upper endpoint value and is closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBKeyRange/upperBound_static)
     */
    upperBound(upper: any, open?: boolean): IDBKeyRange;
};

/**
 * The **`IDBObjectStore`** interface of the IndexedDB API represents an object store in a database. Records within an object store are sorted according to their keys. This sorting enables fast insertion, look-up, and ordered retrieval.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore)
 */
interface IDBObjectStore {
    /**
     * The **`autoIncrement`** read-only property of the IDBObjectStore interface returns the value of the auto increment flag for this object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/autoIncrement)
     */
    readonly autoIncrement: boolean;
    /**
     * The **`indexNames`** read-only property of the IDBObjectStore interface returns a list of the names of indexes on objects in this object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/indexNames)
     */
    readonly indexNames: DOMStringList;
    /**
     * The **`keyPath`** read-only property of the IDBObjectStore interface returns the key path of this object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/keyPath)
     */
    readonly keyPath: string | string[] | null;
    /**
     * The **`name`** property of the IDBObjectStore interface indicates the name of this object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/name)
     */
    name: string;
    /**
     * The **`transaction`** read-only property of the IDBObjectStore interface returns the transaction object to which this object store belongs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/transaction)
     */
    readonly transaction: IDBTransaction;
    /**
     * The **`add()`** method of the IDBObjectStore interface returns an IDBRequest object, and, in a separate thread, creates a structured clone of the value, and stores the cloned value in the object store. This is for adding new records to an object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/add)
     */
    add(value: any, key?: IDBValidKey): IDBRequest<IDBValidKey>;
    /**
     * The **`clear()`** method of the IDBObjectStore interface creates and immediately returns an IDBRequest object, and clears this object store in a separate thread. This is for deleting all the current data out of an object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/clear)
     */
    clear(): IDBRequest<undefined>;
    /**
     * The **`count()`** method of the IDBObjectStore interface returns an IDBRequest object, and, in a separate thread, returns the total number of records that match the provided key or IDBKeyRange. If no arguments are provided, it returns the total number of records in the store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/count)
     */
    count(query?: IDBValidKey | IDBKeyRange): IDBRequest<number>;
    /**
     * The **`createIndex()`** method of the IDBObjectStore interface creates and returns a new IDBIndex object in the connected database. It creates a new field/column defining a new data point for each database record to contain.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/createIndex)
     */
    createIndex(name: string, keyPath: string | string[], options?: IDBIndexParameters): IDBIndex;
    /**
     * The **`delete()`** method of the IDBObjectStore interface returns an IDBRequest object, and, in a separate thread, deletes the specified record or records.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/delete)
     */
    delete(query: IDBValidKey | IDBKeyRange): IDBRequest<undefined>;
    /**
     * The **`deleteIndex()`** method of the IDBObjectStore interface destroys the index with the specified name in the connected database, used during a version upgrade.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/deleteIndex)
     */
    deleteIndex(name: string): void;
    /**
     * The **`get()`** method of the IDBObjectStore interface returns an IDBRequest object, and, in a separate thread, returns the object selected by the specified key. This is for retrieving specific records from an object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/get)
     */
    get(query: IDBValidKey | IDBKeyRange): IDBRequest<any>;
    /**
     * The **`getAll()`** method of the IDBObjectStore interface returns an IDBRequest object containing all objects in the object store matching the specified parameter or all objects in the store if no parameters are given.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/getAll)
     */
    getAll(queryOrOptions?: IDBValidKey | IDBKeyRange | null, count?: number): IDBRequest<any[]>;
    /**
     * The **`getAllKeys()`** method of the IDBObjectStore interface returns an IDBRequest object retrieves record keys for all objects in the object store matching the specified parameter or all objects in the store if no parameters are given.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/getAllKeys)
     */
    getAllKeys(queryOrOptions?: IDBValidKey | IDBKeyRange | null, count?: number): IDBRequest<IDBValidKey[]>;
    /**
     * The **`getKey()`** method of the IDBObjectStore interface returns an IDBRequest object, and, in a separate thread, returns the key selected by the specified query. This is for retrieving specific records from an object store.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/getKey)
     */
    getKey(query: IDBValidKey | IDBKeyRange): IDBRequest<IDBValidKey | undefined>;
    /**
     * The **`index()`** method of the IDBObjectStore interface opens a named index in the current object store, after which it can be used to, for example, return a series of records sorted by that index using a cursor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/index)
     */
    index(name: string): IDBIndex;
    /**
     * The **`openCursor()`** method of the IDBObjectStore interface returns an IDBRequest object, and, in a separate thread, returns a new IDBCursorWithValue object. Used for iterating through an object store with a cursor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/openCursor)
     */
    openCursor(query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection): IDBRequest<IDBCursorWithValue | null>;
    /**
     * The **`openKeyCursor()`** method of the IDBObjectStore interface returns an IDBRequest object whose result will be set to an IDBCursor that can be used to iterate through matching results. Used for iterating through the keys of an object store with a cursor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/openKeyCursor)
     */
    openKeyCursor(query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection): IDBRequest<IDBCursor | null>;
    /**
     * The **`put()`** method of the IDBObjectStore interface updates a given record in a database, or inserts a new record if the given item does not already exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBObjectStore/put)
     */
    put(value: any, key?: IDBValidKey): IDBRequest<IDBValidKey>;
}

declare var IDBObjectStore: {
    prototype: IDBObjectStore;
    new(): IDBObjectStore;
};

interface IDBOpenDBRequestEventMap extends IDBRequestEventMap {
    "blocked": IDBVersionChangeEvent;
    "upgradeneeded": IDBVersionChangeEvent;
}

/**
 * The **`IDBOpenDBRequest`** interface of the IndexedDB API provides access to the results of requests to open or delete databases (performed using IDBFactory.open and IDBFactory.deleteDatabase), using specific event handler attributes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBOpenDBRequest)
 */
interface IDBOpenDBRequest extends IDBRequest<IDBDatabase> {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBOpenDBRequest/blocked_event) */
    onblocked: ((this: IDBOpenDBRequest, ev: IDBVersionChangeEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBOpenDBRequest/upgradeneeded_event) */
    onupgradeneeded: ((this: IDBOpenDBRequest, ev: IDBVersionChangeEvent) => any) | null;
    addEventListener<K extends keyof IDBOpenDBRequestEventMap>(type: K, listener: (this: IDBOpenDBRequest, ev: IDBOpenDBRequestEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof IDBOpenDBRequestEventMap>(type: K, listener: (this: IDBOpenDBRequest, ev: IDBOpenDBRequestEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var IDBOpenDBRequest: {
    prototype: IDBOpenDBRequest;
    new(): IDBOpenDBRequest;
};

interface IDBRequestEventMap {
    "error": Event;
    "success": Event;
}

/**
 * The **`IDBRequest`** interface of the IndexedDB API provides access to results of asynchronous requests to databases and database objects using event handler attributes. Each reading and writing operation on a database is done using a request.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest)
 */
interface IDBRequest<T = any> extends EventTarget {
    /**
     * The **`error`** read-only property of the IDBRequest interface returns the error in the event of an unsuccessful request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/error)
     */
    readonly error: DOMException | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/error_event) */
    onerror: ((this: IDBRequest<T>, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/success_event) */
    onsuccess: ((this: IDBRequest<T>, ev: Event) => any) | null;
    /**
     * The **`readyState`** read-only property of the IDBRequest interface returns the state of the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/readyState)
     */
    readonly readyState: IDBRequestReadyState;
    /**
     * The **`result`** read-only property of the IDBRequest interface returns the result of the request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/result)
     */
    readonly result: T;
    /**
     * The **`source`** read-only property of the IDBRequest interface returns the source of the request, such as an Index or an object store. If no source exists (such as when calling IDBFactory.open), it returns null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/source)
     */
    readonly source: IDBObjectStore | IDBIndex | IDBCursor;
    /**
     * The **`transaction`** read-only property of the IDBRequest interface returns the transaction for the request, that is, the transaction the request is being made inside.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBRequest/transaction)
     */
    readonly transaction: IDBTransaction | null;
    addEventListener<K extends keyof IDBRequestEventMap>(type: K, listener: (this: IDBRequest<T>, ev: IDBRequestEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof IDBRequestEventMap>(type: K, listener: (this: IDBRequest<T>, ev: IDBRequestEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var IDBRequest: {
    prototype: IDBRequest;
    new(): IDBRequest;
};

interface IDBTransactionEventMap {
    "abort": Event;
    "complete": Event;
    "error": Event;
}

/**
 * The **`IDBTransaction`** interface of the IndexedDB API provides a static, asynchronous transaction on a database using event handler attributes. All reading and writing of data is done within transactions. You use IDBDatabase to start transactions, IDBTransaction to set the mode of the transaction (e.g., is it readonly or readwrite), and you access an IDBObjectStore to make a request. You can also use an IDBTransaction object to abort transactions.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction)
 */
interface IDBTransaction extends EventTarget {
    /**
     * The **`db`** read-only property of the IDBTransaction interface returns the database connection with which this transaction is associated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/db)
     */
    readonly db: IDBDatabase;
    /**
     * The **`durability`** read-only property of the IDBTransaction interface returns the durability hint the transaction was created with. This is a hint to the user agent of whether to prioritize performance or durability when committing the transaction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/durability)
     */
    readonly durability: IDBTransactionDurability;
    /**
     * The **`IDBTransaction.error`** property of the IDBTransaction interface returns the type of error when there is an unsuccessful transaction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/error)
     */
    readonly error: DOMException | null;
    /**
     * The **`mode`** read-only property of the IDBTransaction interface returns the current mode for accessing the data in the object stores in the scope of the transaction (i.e., is the mode to be read-only, or do you want to write to the object stores?) The default value is readonly.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/mode)
     */
    readonly mode: IDBTransactionMode;
    /**
     * The **`objectStoreNames`** read-only property of the IDBTransaction interface returns a DOMStringList of names of IDBObjectStore objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/objectStoreNames)
     */
    readonly objectStoreNames: DOMStringList;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/abort_event) */
    onabort: ((this: IDBTransaction, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/complete_event) */
    oncomplete: ((this: IDBTransaction, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/error_event) */
    onerror: ((this: IDBTransaction, ev: Event) => any) | null;
    /**
     * The **`abort()`** method of the IDBTransaction interface rolls back all the changes to objects in the database associated with this transaction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/abort)
     */
    abort(): void;
    /**
     * The **`commit()`** method of the IDBTransaction interface commits the transaction if it is called on an active transaction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/commit)
     */
    commit(): void;
    /**
     * The **`objectStore()`** method of the IDBTransaction interface returns an object store that has already been added to the scope of this transaction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBTransaction/objectStore)
     */
    objectStore(name: string): IDBObjectStore;
    addEventListener<K extends keyof IDBTransactionEventMap>(type: K, listener: (this: IDBTransaction, ev: IDBTransactionEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof IDBTransactionEventMap>(type: K, listener: (this: IDBTransaction, ev: IDBTransactionEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var IDBTransaction: {
    prototype: IDBTransaction;
    new(): IDBTransaction;
};

/**
 * The **`IDBVersionChangeEvent`** interface of the IndexedDB API indicates that the version of the database has changed, as the result of an onupgradeneeded event handler function.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBVersionChangeEvent)
 */
interface IDBVersionChangeEvent extends Event {
    /**
     * The **`newVersion`** read-only property of the IDBVersionChangeEvent interface returns the new version number of the database.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBVersionChangeEvent/newVersion)
     */
    readonly newVersion: number | null;
    /**
     * The **`oldVersion`** read-only property of the IDBVersionChangeEvent interface returns the old version number of the database.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IDBVersionChangeEvent/oldVersion)
     */
    readonly oldVersion: number;
}

declare var IDBVersionChangeEvent: {
    prototype: IDBVersionChangeEvent;
    new(type: string, eventInitDict?: IDBVersionChangeEventInit): IDBVersionChangeEvent;
};

/**
 * The **`IIRFilterNode`** interface of the Web Audio API is an AudioNode processor which implements a general infinite impulse response (IIR) filter; this type of filter can be used to implement tone control devices and graphic equalizers as well. It lets the parameters of the filter response be specified, so that it can be tuned as needed.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IIRFilterNode)
 */
interface IIRFilterNode extends AudioNode {
    /**
     * The **`getFrequencyResponse()`** method of the IIRFilterNode interface takes the current filtering algorithm's settings and calculates the frequency response for frequencies specified in a specified array of frequencies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IIRFilterNode/getFrequencyResponse)
     */
    getFrequencyResponse(frequencyHz: Float32Array<ArrayBuffer>, magResponse: Float32Array<ArrayBuffer>, phaseResponse: Float32Array<ArrayBuffer>): void;
}

declare var IIRFilterNode: {
    prototype: IIRFilterNode;
    new(context: BaseAudioContext, options: IIRFilterOptions): IIRFilterNode;
};

/**
 * The **`IdleDeadline`** interface is used as the data type of the input parameter to idle callbacks established by calling Window.requestIdleCallback(). It offers a method, timeRemaining(), which lets you determine how much longer the user agent estimates it will remain idle and a property, didTimeout, which lets you determine if your callback is executing because its timeout duration expired.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IdleDeadline)
 */
interface IdleDeadline {
    /**
     * The read-only **`didTimeout`** property on the IdleDeadline interface is a Boolean value which indicates whether or not the idle callback is being invoked because the timeout interval specified when Window.requestIdleCallback() was called has expired.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IdleDeadline/didTimeout)
     */
    readonly didTimeout: boolean;
    /**
     * The **`timeRemaining()`** method on the IdleDeadline interface returns the estimated number of milliseconds remaining in the current idle period. The callback can call this method at any time to determine how much time it can continue to work before it must return. For example, if the callback finishes a task and has another one to begin, it can call timeRemaining() to see if there's enough time to complete the next task. If there isn't, the callback can just return immediately, or look for other work to do with the remaining time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IdleDeadline/timeRemaining)
     */
    timeRemaining(): DOMHighResTimeStamp;
}

declare var IdleDeadline: {
    prototype: IdleDeadline;
    new(): IdleDeadline;
};

/**
 * The **`ImageBitmap`** interface represents a bitmap image which can be drawn to a <canvas> without undue latency. It can be created from a variety of source objects using the Window.createImageBitmap() or WorkerGlobalScope.createImageBitmap() factory method. ImageBitmap provides an asynchronous and resource efficient pathway to prepare textures for rendering in WebGL.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmap)
 */
interface ImageBitmap {
    /**
     * The **`ImageBitmap.height`** read-only property returns the ImageBitmap object's height in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmap/height)
     */
    readonly height: number;
    /**
     * The **`ImageBitmap.width`** read-only property returns the ImageBitmap object's width in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmap/width)
     */
    readonly width: number;
    /**
     * The **`ImageBitmap.close()`** method disposes of all graphical resources associated with an ImageBitmap.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmap/close)
     */
    close(): void;
}

declare var ImageBitmap: {
    prototype: ImageBitmap;
    new(): ImageBitmap;
};

/**
 * The **`ImageBitmapRenderingContext`** interface is a canvas rendering context that provides the functionality to replace the canvas's contents with the given ImageBitmap. Its context id (the first argument to HTMLCanvasElement.getContext() or OffscreenCanvas.getContext()) is "bitmaprenderer".
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmapRenderingContext)
 */
interface ImageBitmapRenderingContext {
    /**
     * The **`ImageBitmapRenderingContext.canvas`** property, part of the Canvas API, is a read-only reference to the HTMLCanvasElement or OffscreenCanvas object that is associated with the given context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmapRenderingContext/canvas)
     */
    readonly canvas: HTMLCanvasElement | OffscreenCanvas;
    /**
     * The **`ImageBitmapRenderingContext.transferFromImageBitmap()`** method displays the given ImageBitmap in the canvas associated with this rendering context. The ownership of the ImageBitmap is transferred to the canvas as well.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageBitmapRenderingContext/transferFromImageBitmap)
     */
    transferFromImageBitmap(bitmap: ImageBitmap | null): void;
}

declare var ImageBitmapRenderingContext: {
    prototype: ImageBitmapRenderingContext;
    new(): ImageBitmapRenderingContext;
};

/**
 * The **`ImageCapture`** interface of the MediaStream Image Capture API provides methods to enable the capture of images or photos from a camera or other photographic device. It provides an interface for capturing images from a photographic device referenced through a valid MediaStreamTrack.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageCapture)
 */
interface ImageCapture {
    /**
     * The **`track`** read-only property of the ImageCapture interface returns a reference to the MediaStreamTrack passed to the ImageCapture() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageCapture/track)
     */
    readonly track: MediaStreamTrack;
    /**
     * The **`getPhotoCapabilities()`** method of the ImageCapture interface returns a Promise that resolves with an object containing the ranges of available configuration options.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageCapture/getPhotoCapabilities)
     */
    getPhotoCapabilities(): Promise<PhotoCapabilities>;
    /**
     * The **`getPhotoSettings()`** method of the ImageCapture interface returns a Promise that resolves with an object containing the current photo configuration settings.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageCapture/getPhotoSettings)
     */
    getPhotoSettings(): Promise<PhotoSettings>;
    /**
     * The **`grabFrame()`** method of the ImageCapture interface takes a snapshot of the live video in a MediaStreamTrack and returns a Promise that resolves with an ImageBitmap containing the snapshot.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageCapture/grabFrame)
     */
    grabFrame(): Promise<ImageBitmap>;
    /**
     * The **`takePhoto()`** method of the ImageCapture interface takes a single exposure using the video capture device sourcing a MediaStreamTrack and returns a Promise that resolves with a Blob containing the data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageCapture/takePhoto)
     */
    takePhoto(photoSettings?: PhotoSettings): Promise<Blob>;
}

declare var ImageCapture: {
    prototype: ImageCapture;
    new(videoTrack: MediaStreamTrack): ImageCapture;
};

/**
 * The **`ImageData`** interface represents the underlying pixel data of an area of a <canvas> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageData)
 */
interface ImageData {
    /**
     * The read-only **`ImageData.colorSpace`** property is a string indicating the color space of the image data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageData/colorSpace)
     */
    readonly colorSpace: PredefinedColorSpace;
    /**
     * The readonly **`ImageData.data`** property returns a Uint8ClampedArray or Float16Array that contains the ImageData object's pixel data. Data is stored as a one-dimensional array in the RGBA order.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageData/data)
     */
    readonly data: ImageDataArray;
    /**
     * The readonly **`ImageData.height`** property returns the number of rows in the ImageData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageData/height)
     */
    readonly height: number;
    /**
     * The readonly **`ImageData.width`** property returns the number of pixels per row in the ImageData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageData/width)
     */
    readonly width: number;
}

declare var ImageData: {
    prototype: ImageData;
    new(sw: number, sh: number, settings?: ImageDataSettings): ImageData;
    new(data: ImageDataArray, sw: number, sh?: number, settings?: ImageDataSettings): ImageData;
};

/**
 * The **`ImageDecoder`** interface of the WebCodecs API provides a way to unpack and decode encoded image data.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder)
 */
interface ImageDecoder {
    /**
     * The **`complete`** read-only property of the ImageDecoder interface returns true if encoded data has completed buffering.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/complete)
     */
    readonly complete: boolean;
    /**
     * The **`completed`** read-only property of the ImageDecoder interface returns a promise that resolves once encoded data has finished buffering.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/completed)
     */
    readonly completed: Promise<void>;
    /**
     * The **`tracks`** read-only property of the ImageDecoder interface returns a list of the tracks in the encoded image data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/tracks)
     */
    readonly tracks: ImageTrackList;
    /**
     * The **`type`** read-only property of the ImageDecoder interface reflects the MIME type configured during construction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/type)
     */
    readonly type: string;
    /**
     * The **`close()`** method of the ImageDecoder interface ends all pending work and releases system resources.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/close)
     */
    close(): void;
    /**
     * The **`decode()`** method of the ImageDecoder interface enqueues a control message to decode the frame of an image.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/decode)
     */
    decode(options?: ImageDecodeOptions): Promise<ImageDecodeResult>;
    /**
     * The **`reset()`** method of the ImageDecoder interface aborts all pending decode() operations; rejecting all pending promises. All other state will be unchanged. Class methods can continue to be invoked after reset(). E.g., calling decode() after reset() is permitted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/reset)
     */
    reset(): void;
}

declare var ImageDecoder: {
    prototype: ImageDecoder;
    new(init: ImageDecoderInit): ImageDecoder;
    /**
     * The **`ImageDecoder.isTypeSupported()`** static method checks if a given MIME type can be decoded by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageDecoder/isTypeSupported_static)
     */
    isTypeSupported(type: string): Promise<boolean>;
};

/**
 * The **`ImageTrack`** interface of the WebCodecs API represents an individual image track.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrack)
 */
interface ImageTrack {
    /**
     * The **`animated`** property of the ImageTrack interface returns true if the track is animated and therefore has multiple frames.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrack/animated)
     */
    readonly animated: boolean;
    /**
     * The **`frameCount`** property of the ImageTrack interface returns the number of frames in the track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrack/frameCount)
     */
    readonly frameCount: number;
    /**
     * The **`repetitionCount`** property of the ImageTrack interface returns the number of repetitions of this track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrack/repetitionCount)
     */
    readonly repetitionCount: number;
    /**
     * The **`selected`** property of the ImageTrack interface returns true if the track is selected for decoding.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrack/selected)
     */
    selected: boolean;
}

declare var ImageTrack: {
    prototype: ImageTrack;
    new(): ImageTrack;
};

/**
 * The **`ImageTrackList`** interface of the WebCodecs API represents a list of image tracks.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrackList)
 */
interface ImageTrackList {
    /**
     * The **`length`** property of the ImageTrackList interface returns the length of the ImageTrackList.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrackList/length)
     */
    readonly length: number;
    /**
     * The **`ready`** property of the ImageTrackList interface returns a Promise that resolves when the ImageTrackList is populated with tracks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrackList/ready)
     */
    readonly ready: Promise<void>;
    /**
     * The **`selectedIndex`** property of the ImageTrackList interface returns the index of the selected track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrackList/selectedIndex)
     */
    readonly selectedIndex: number;
    /**
     * The **`selectedTrack`** property of the ImageTrackList interface returns an ImageTrack object representing the currently selected track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ImageTrackList/selectedTrack)
     */
    readonly selectedTrack: ImageTrack | null;
    [index: number]: ImageTrack;
}

declare var ImageTrackList: {
    prototype: ImageTrackList;
    new(): ImageTrackList;
};

interface ImportMeta {
    url: string;
    resolve(specifier: string): string;
}

/**
 * The **`InputDeviceInfo`** interface of the Media Capture and Streams API gives access to the capabilities of the input device that it represents.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputDeviceInfo)
 */
interface InputDeviceInfo extends MediaDeviceInfo {
    /**
     * The **`getCapabilities()`** method of the InputDeviceInfo interface returns a MediaTrackCapabilities object describing the primary audio or video track of the device's MediaStream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputDeviceInfo/getCapabilities)
     */
    getCapabilities(): MediaTrackCapabilities;
}

declare var InputDeviceInfo: {
    prototype: InputDeviceInfo;
    new(): InputDeviceInfo;
};

/**
 * The **`InputEvent`** interface represents an event notifying the user of editable content changes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputEvent)
 */
interface InputEvent extends UIEvent {
    /**
     * The **`data`** read-only property of the InputEvent interface returns a string with inserted characters. This may be an empty string if the change doesn't insert text, such as when characters are deleted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputEvent/data)
     */
    readonly data: string | null;
    /**
     * The **`dataTransfer`** read-only property of the InputEvent interface returns a DataTransfer object containing information about richtext or plaintext data being added to or removed from editable content.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputEvent/dataTransfer)
     */
    readonly dataTransfer: DataTransfer | null;
    /**
     * The **`inputType`** read-only property of the InputEvent interface returns the type of change made to editable content. Possible changes include for example inserting, deleting, and formatting text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputEvent/inputType)
     */
    readonly inputType: string;
    /**
     * The **`InputEvent.isComposing`** read-only property returns a boolean value indicating if the event is fired after compositionstart and before compositionend.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputEvent/isComposing)
     */
    readonly isComposing: boolean;
    /**
     * The **`getTargetRanges()`** method of the InputEvent interface returns an array of StaticRange objects that will be affected by a change to the DOM if the input event is not canceled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/InputEvent/getTargetRanges)
     */
    getTargetRanges(): StaticRange[];
}

declare var InputEvent: {
    prototype: InputEvent;
    new(type: string, eventInitDict?: InputEventInit): InputEvent;
};

/**
 * The **`IntersectionObserver`** interface of the Intersection Observer API provides a way to asynchronously observe changes in the intersection of a target element with an ancestor element or with a top-level document's viewport. The ancestor element or viewport is referred to as the root.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver)
 */
interface IntersectionObserver {
    /**
     * The **`root`** read-only property of the IntersectionObserver interface identifies the Element or Document whose bounds are treated as the bounding box of the viewport for the element which is the observer's target.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/root)
     */
    readonly root: Element | Document | null;
    /**
     * The **`rootMargin`** read-only property of the IntersectionObserver interface is a string with syntax similar to that of the CSS margin property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/rootMargin)
     */
    readonly rootMargin: string;
    /**
     * The **`scrollMargin`** read-only property of the IntersectionObserver interface adds a margin to all nested scroll containers within the root element, including the root element if it is a scroll container.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/scrollMargin)
     */
    readonly scrollMargin: string;
    /**
     * The **`thresholds`** read-only property of the IntersectionObserver interface returns the list of intersection thresholds that was specified when the observer was instantiated with IntersectionObserver().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/thresholds)
     */
    readonly thresholds: ReadonlyArray<number>;
    /**
     * The **`disconnect()`** method of the IntersectionObserver interface stops the observer watching all of its target elements for visibility changes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/disconnect)
     */
    disconnect(): void;
    /**
     * The **`observe()`** method of the IntersectionObserver interface adds an element to the set of target elements being watched by the IntersectionObserver. One observer has one set of thresholds and one root, but can watch multiple target elements for visibility changes in keeping with those.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/observe)
     */
    observe(target: Element): void;
    /**
     * The **`takeRecords()`** method of the IntersectionObserver interface returns an array of IntersectionObserverEntry objects, one for each targeted element which has experienced an intersection change since the last time the intersections were checked, either explicitly through a call to this method or implicitly by an automatic call to the observer's callback.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/takeRecords)
     */
    takeRecords(): IntersectionObserverEntry[];
    /**
     * The **`unobserve()`** method of the IntersectionObserver interface instructs the IntersectionObserver to stop observing the specified target element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserver/unobserve)
     */
    unobserve(target: Element): void;
}

declare var IntersectionObserver: {
    prototype: IntersectionObserver;
    new(callback: IntersectionObserverCallback, options?: IntersectionObserverInit): IntersectionObserver;
};

/**
 * The **`IntersectionObserverEntry`** interface of the Intersection Observer API describes the intersection between the target element and its root container at a specific moment of transition.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry)
 */
interface IntersectionObserverEntry {
    /**
     * The **`boundingClientRect`** read-only property of the IntersectionObserverEntry interface returns a DOMRectReadOnly which in essence describes a rectangle describing the smallest rectangle that contains the entire target element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/boundingClientRect)
     */
    readonly boundingClientRect: DOMRectReadOnly;
    /**
     * The **`intersectionRatio`** read-only property of the IntersectionObserverEntry interface tells you how much of the target element is currently visible within the root's intersection ratio, as a value between 0.0 and 1.0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/intersectionRatio)
     */
    readonly intersectionRatio: number;
    /**
     * The **`intersectionRect`** read-only property of the IntersectionObserverEntry interface is a DOMRectReadOnly object which describes the smallest rectangle that contains the entire portion of the target element which is currently visible within the intersection root.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/intersectionRect)
     */
    readonly intersectionRect: DOMRectReadOnly;
    /**
     * The **`isIntersecting`** read-only property of the IntersectionObserverEntry interface is a Boolean value which is true if the target element intersects with the intersection observer's root.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/isIntersecting)
     */
    readonly isIntersecting: boolean;
    /**
     * The **`rootBounds`** read-only property of the IntersectionObserverEntry interface is a DOMRectReadOnly corresponding to the target's root intersection rectangle, offset by the IntersectionObserver.rootMargin if one is specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/rootBounds)
     */
    readonly rootBounds: DOMRectReadOnly | null;
    /**
     * The **`target`** read-only property of the IntersectionObserverEntry interface indicates which targeted Element has changed its amount of intersection with the intersection root.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/target)
     */
    readonly target: Element;
    /**
     * The **`time`** read-only property of the IntersectionObserverEntry interface is a DOMHighResTimeStamp that indicates the time at which the intersection change occurred relative to the time at which the document was created.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/IntersectionObserverEntry/time)
     */
    readonly time: DOMHighResTimeStamp;
}

declare var IntersectionObserverEntry: {
    prototype: IntersectionObserverEntry;
    new(): IntersectionObserverEntry;
};

/**
 * The **`KHR_parallel_shader_compile`** extension is part of the WebGL API and enables a non-blocking poll operation, so that compile/link status availability (COMPLETION_STATUS_KHR) can be queried without potentially incurring stalls. In other words you can check the status of your shaders compiling without blocking the runtime.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KHR_parallel_shader_compile)
 */
interface KHR_parallel_shader_compile {
    readonly COMPLETION_STATUS_KHR: 0x91B1;
}

/**
 * **`KeyboardEvent`** objects describe a user interaction with the keyboard; each event describes a single interaction between the user and a key (or combination of a key with modifier keys) on the keyboard. The event type (keydown, keypress, or keyup) identifies what kind of keyboard activity occurred.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent)
 */
interface KeyboardEvent extends UIEvent {
    /**
     * The **`KeyboardEvent.altKey`** read-only property is a boolean value that indicates if the alt key (Option or ⌥ on macOS) was pressed (true) or not (false) when the event occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/altKey)
     */
    readonly altKey: boolean;
    /**
     * The **`charCode`** read-only property of the KeyboardEvent interface returns the Unicode value of a character key pressed during a keypress event.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/charCode)
     */
    readonly charCode: number;
    /**
     * The **`KeyboardEvent.code`** property represents a physical key on the keyboard (as opposed to the character generated by pressing the key). In other words, this property returns a value that isn't altered by keyboard layout or the state of the modifier keys.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/code)
     */
    readonly code: string;
    /**
     * The **`KeyboardEvent.ctrlKey`** read-only property returns a boolean value that indicates if the control key was pressed (true) or not (false) when the event occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/ctrlKey)
     */
    readonly ctrlKey: boolean;
    /**
     * The **`KeyboardEvent.isComposing`** read-only property returns a boolean value indicating if the event is fired within a composition session, i.e., after compositionstart and before compositionend.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/isComposing)
     */
    readonly isComposing: boolean;
    /**
     * The KeyboardEvent interface's **`key`** read-only property returns the value of the key pressed by the user, taking into consideration the state of modifier keys such as Shift as well as the keyboard locale and layout.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/key)
     */
    readonly key: string;
    /**
     * The deprecated **`KeyboardEvent.keyCode`** read-only property represents a system and implementation dependent numerical code identifying the unmodified value of the pressed key.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/keyCode)
     */
    readonly keyCode: number;
    /**
     * The **`KeyboardEvent.location`** read-only property returns an unsigned long representing the location of the key on the keyboard or other input device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/location)
     */
    readonly location: number;
    /**
     * The **`KeyboardEvent.metaKey`** read-only property returning a boolean value that indicates if the Meta key was pressed (true) or not (false) when the event occurred. Some operating systems may intercept the key so it is never detected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/metaKey)
     */
    readonly metaKey: boolean;
    /**
     * The **`repeat`** read-only property of the KeyboardEvent interface returns a boolean value that is true if the given key is being held down such that it is automatically repeating.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/repeat)
     */
    readonly repeat: boolean;
    /**
     * The **`KeyboardEvent.shiftKey`** read-only property is a boolean value that indicates if the shift key was pressed (true) or not (false) when the event occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/shiftKey)
     */
    readonly shiftKey: boolean;
    /**
     * The **`KeyboardEvent.getModifierState()`** method returns the current state of the specified modifier key: true if the modifier is active (that is the modifier key is pressed or locked), otherwise, false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/getModifierState)
     */
    getModifierState(keyArg: string): boolean;
    /**
     * The **`KeyboardEvent.initKeyboardEvent()`** method initializes the attributes of a keyboard event object. This method was introduced in draft of DOM Level 3 Events, but deprecated in newer draft. Gecko won't support this feature since implementing this method as experimental broke existing web apps (see Firefox bug 999645). Web applications should use constructor instead of this if it's available.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyboardEvent/initKeyboardEvent)
     */
    initKeyboardEvent(typeArg: string, bubblesArg?: boolean, cancelableArg?: boolean, viewArg?: Window | null, keyArg?: string, locationArg?: number, ctrlKey?: boolean, altKey?: boolean, shiftKey?: boolean, metaKey?: boolean): void;
    readonly DOM_KEY_LOCATION_STANDARD: 0x00;
    readonly DOM_KEY_LOCATION_LEFT: 0x01;
    readonly DOM_KEY_LOCATION_RIGHT: 0x02;
    readonly DOM_KEY_LOCATION_NUMPAD: 0x03;
}

declare var KeyboardEvent: {
    prototype: KeyboardEvent;
    new(type: string, eventInitDict?: KeyboardEventInit): KeyboardEvent;
    readonly DOM_KEY_LOCATION_STANDARD: 0x00;
    readonly DOM_KEY_LOCATION_LEFT: 0x01;
    readonly DOM_KEY_LOCATION_RIGHT: 0x02;
    readonly DOM_KEY_LOCATION_NUMPAD: 0x03;
};

/**
 * The **`KeyframeEffect`** interface of the Web Animations API lets us create sets of animatable properties and values, called keyframes. These can then be played using the Animation() constructor.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect)
 */
interface KeyframeEffect extends AnimationEffect {
    /**
     * The **`composite`** property of a KeyframeEffect resolves how an element's animation impacts its underlying property values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect/composite)
     */
    composite: CompositeOperation;
    /**
     * The **`iterationComposite`** property of a KeyframeEffect resolves how the animation's property value changes accumulate or override each other upon each of the animation's iterations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect/iterationComposite)
     */
    iterationComposite: IterationCompositeOperation;
    /**
     * The **`pseudoElement`** property of a KeyframeEffect interface is a string representing the pseudo-element being animated. It may be null for animations that do not target a pseudo-element. It performs as both a getter and a setter, except with animations and transitions generated by CSS.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect/pseudoElement)
     */
    pseudoElement: string | null;
    /**
     * The **`target`** property of a KeyframeEffect interface represents the element or pseudo-element being animated. It may be null for animations that do not target a specific element. It performs as both a getter and a setter, except with animations and transitions generated by CSS.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect/target)
     */
    target: Element | null;
    /**
     * The **`getKeyframes()`** method of a KeyframeEffect returns an Array of the computed keyframes that make up this animation along with their computed offsets.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect/getKeyframes)
     */
    getKeyframes(): ComputedKeyframe[];
    /**
     * The **`setKeyframes()`** method of the KeyframeEffect interface replaces the keyframes that make up the affected KeyframeEffect with a new set of keyframes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/KeyframeEffect/setKeyframes)
     */
    setKeyframes(keyframes: Keyframe[] | PropertyIndexedKeyframes | null): void;
}

declare var KeyframeEffect: {
    prototype: KeyframeEffect;
    new(target: Element | null, keyframes: Keyframe[] | PropertyIndexedKeyframes | null, options?: number | KeyframeEffectOptions): KeyframeEffect;
    new(source: KeyframeEffect): KeyframeEffect;
};

/**
 * The **`LargestContentfulPaint`** interface provides timing information about the largest image or text paint before user input on a web page.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint)
 */
interface LargestContentfulPaint extends PerformanceEntry, PaintTimingMixin {
    /**
     * The **`element`** read-only property of the LargestContentfulPaint interface returns an object representing the Element that is the largest contentful paint.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/element)
     */
    readonly element: Element | null;
    /**
     * The **`id`** read-only property of the LargestContentfulPaint interface returns the ID of the element that is the largest contentful paint.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/id)
     */
    readonly id: string;
    /**
     * The **`loadTime`** read-only property of the LargestContentfulPaint interface returns the time that the element was loaded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/loadTime)
     */
    readonly loadTime: DOMHighResTimeStamp;
    /**
     * The **`renderTime`** read-only property of the LargestContentfulPaint interface represents the time that the element was rendered to the screen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/renderTime)
     */
    readonly renderTime: DOMHighResTimeStamp;
    /**
     * The **`size`** read-only property of the LargestContentfulPaint interface returns the intrinsic size of the element that is the largest contentful paint.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/size)
     */
    readonly size: number;
    /**
     * The **`url`** read-only property of the LargestContentfulPaint interface returns the request URL of the element, if the element is an image.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/url)
     */
    readonly url: string;
    /**
     * The **`toJSON()`** method of the LargestContentfulPaint interface is a serializer; it returns a JSON representation of the LargestContentfulPaint object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LargestContentfulPaint/toJSON)
     */
    toJSON(): any;
}

declare var LargestContentfulPaint: {
    prototype: LargestContentfulPaint;
    new(): LargestContentfulPaint;
};

interface LinkStyle {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLLinkElement/sheet) */
    readonly sheet: CSSStyleSheet | null;
}
