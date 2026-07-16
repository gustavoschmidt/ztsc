
/**
 * The **`Document`** interface represents any web page loaded in the browser and serves as an entry point into the web page's content, which is the DOM tree.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document)
 */
interface Document extends Node, DocumentOrShadowRoot, FontFaceSource, GlobalEventHandlers, NonElementParentNode, ParentNode, XPathEvaluatorBase {
    /**
     * The **`URL`** read-only property of the Document interface returns the document location as a string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/URL)
     */
    readonly URL: string;
    /**
     * The **`activeViewTransition`** read-only property of the Document interface returns a ViewTransition instance representing the view transition currently active on the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/activeViewTransition)
     */
    readonly activeViewTransition: ViewTransition | null;
    /**
     * Returns or sets the color of an active link in the document body. A link is active during the time between mousedown and mouseup events.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/alinkColor)
     */
    alinkColor: string;
    /**
     * The Document interface's read-only **`all`** property returns an HTMLAllCollection rooted at the document node.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/all)
     */
    readonly all: HTMLAllCollection;
    /**
     * The **`anchors`** read-only property of the Document interface returns a list of all of the anchors in the document.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/anchors)
     */
    readonly anchors: HTMLCollectionOf<HTMLAnchorElement>;
    /**
     * The **`applets`** property of the Document returns an empty HTMLCollection. This property is kept only for compatibility reasons; in older versions of browsers, it returned a list of the applets within a document.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/applets)
     */
    readonly applets: HTMLCollection;
    /**
     * The deprecated **`bgColor`** property gets or sets the background color of the current document.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/bgColor)
     */
    bgColor: string;
    /**
     * The **`Document.body`** property represents the <body> or <frameset> node of the current document, or null if no such element exists.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/body)
     */
    body: HTMLElement;
    /**
     * The **`Document.characterSet`** read-only property returns the character encoding of the document that it's currently rendered with.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/characterSet)
     */
    readonly characterSet: string;
    /**
     * @deprecated This is a legacy alias of `characterSet`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/characterSet)
     */
    readonly charset: string;
    /**
     * The **`Document.compatMode`** read-only property indicates whether the document is rendered in Quirks mode or Standards mode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/compatMode)
     */
    readonly compatMode: string;
    /**
     * The **`Document.contentType`** read-only property returns the MIME type that the document is being rendered as. This may come from HTTP headers or other sources of MIME information, and might be affected by automatic type conversions performed by either the browser or extensions.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/contentType)
     */
    readonly contentType: string;
    /**
     * The Document property **`cookie`** lets you read and write cookies associated with the document. It serves as a getter and setter for the actual values of the cookies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/cookie)
     */
    cookie: string;
    /**
     * The **`Document.currentScript`** property returns the <script> element whose script is currently being processed and isn't a JavaScript module. (For modules use import.meta instead.)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/currentScript)
     */
    readonly currentScript: HTMLOrSVGScriptElement | null;
    /**
     * In browsers, **`document.defaultView`** returns the window object associated with a document, or null if none is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/defaultView)
     */
    readonly defaultView: (WindowProxy & typeof globalThis) | null;
    /**
     * **`document.designMode`** controls whether the entire document is editable. Valid values are "on" and "off". According to the specification, this property is meant to default to "off". Firefox follows this standard. The earlier versions of Chrome and IE default to "inherit". Starting in Chrome 43, the default is "off" and "inherit" is no longer supported. In IE6-10, the value is capitalized.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/designMode)
     */
    designMode: string;
    /**
     * The **`Document.dir`** property is a string representing the directionality of the text of the document, whether left to right (default) or right to left. Possible values are 'rtl', right to left, and 'ltr', left to right.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/dir)
     */
    dir: string;
    /**
     * The **`doctype`** read-only property of the Document interface is a DocumentType object representing the Document Type Declaration (DTD) associated with the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/doctype)
     */
    readonly doctype: DocumentType | null;
    /**
     * The **`documentElement`** read-only property of the Document interface returns the Element that is the root element of the document (for example, the <html> element for HTML documents).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/documentElement)
     */
    readonly documentElement: HTMLElement;
    /**
     * The **`documentURI`** read-only property of the Document interface returns the document location as a string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/documentURI)
     */
    readonly documentURI: string;
    /**
     * The **`domain`** property of the Document interface gets/sets the domain portion of the origin of the current document, as used by the same-origin policy.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/domain)
     */
    domain: string;
    /**
     * The **`embeds`** read-only property of the Document interface returns a list of the embedded <embed> elements within the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/embeds)
     */
    readonly embeds: HTMLCollectionOf<HTMLEmbedElement>;
    /**
     * **`fgColor`** gets/sets the foreground color, or text color, of the current document.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fgColor)
     */
    fgColor: string;
    /**
     * The **`forms`** read-only property of the Document interface returns an HTMLCollection listing all the <form> elements contained in the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/forms)
     */
    readonly forms: HTMLCollectionOf<HTMLFormElement>;
    /**
     * The **`fragmentDirective`** read-only property of the Document interface returns the FragmentDirective for the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fragmentDirective)
     */
    readonly fragmentDirective: FragmentDirective;
    /**
     * The obsolete Document interface's **`fullscreen`** read-only property reports whether or not the document is currently displaying content in fullscreen mode.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fullscreen)
     */
    readonly fullscreen: boolean;
    /**
     * The read-only **`fullscreenEnabled`** property on the Document interface indicates whether or not fullscreen mode is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fullscreenEnabled)
     */
    readonly fullscreenEnabled: boolean;
    /**
     * The **`head`** read-only property of the Document interface returns the <head> element of the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/head)
     */
    readonly head: HTMLHeadElement;
    /**
     * The **`Document.hidden`** read-only property returns a Boolean value indicating if the page is considered hidden or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/hidden)
     */
    readonly hidden: boolean;
    /**
     * The **`images`** read-only property of the Document interface returns a collection of the images in the current HTML document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/images)
     */
    readonly images: HTMLCollectionOf<HTMLImageElement>;
    /**
     * The **`Document.implementation`** property returns a DOMImplementation object associated with the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/implementation)
     */
    readonly implementation: DOMImplementation;
    /**
     * @deprecated This is a legacy alias of `characterSet`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/characterSet)
     */
    readonly inputEncoding: string;
    /**
     * The **`lastModified`** property of the Document interface returns a string containing the date and local time on which the current document was last modified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/lastModified)
     */
    readonly lastModified: string;
    /**
     * The **`Document.linkColor`** property gets/sets the color of links within the document.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/linkColor)
     */
    linkColor: string;
    /**
     * The **`links`** read-only property of the Document interface returns a collection of all <area> elements and <a> elements in a document with a value for the href attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/links)
     */
    readonly links: HTMLCollectionOf<HTMLAnchorElement | HTMLAreaElement>;
    /**
     * The read-only **`location`** property of the Document interface returns a Location object, which contains information about the URL of the document and provides methods for changing that URL and loading another URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/location)
     */
    get location(): Location;
    set location(href: string);
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fullscreenchange_event) */
    onfullscreenchange: ((this: Document, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fullscreenerror_event) */
    onfullscreenerror: ((this: Document, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/pointerlockchange_event) */
    onpointerlockchange: ((this: Document, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/pointerlockerror_event) */
    onpointerlockerror: ((this: Document, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/readystatechange_event) */
    onreadystatechange: ((this: Document, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/visibilitychange_event) */
    onvisibilitychange: ((this: Document, ev: Event) => any) | null;
    readonly ownerDocument: null;
    /**
     * The read-only **`pictureInPictureEnabled`** property of the Document interface indicates whether or not picture-in-picture mode is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/pictureInPictureEnabled)
     */
    readonly pictureInPictureEnabled: boolean;
    /**
     * The **`plugins`** read-only property of the Document interface returns an HTMLCollection object containing one or more HTMLEmbedElements representing the <embed> elements in the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/plugins)
     */
    readonly plugins: HTMLCollectionOf<HTMLEmbedElement>;
    /**
     * The **`Document.readyState`** property describes the loading state of the document. When the value of this property changes, a readystatechange event fires on the document object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/readyState)
     */
    readonly readyState: DocumentReadyState;
    /**
     * The **`Document.referrer`** property returns the URI of the page that linked to this page.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/referrer)
     */
    readonly referrer: string;
    /**
     * **`Document.rootElement`** returns the Element that is the root element of the document if it is an <svg> element, otherwise null. It is deprecated in favor of Document.documentElement, which returns the root element for all documents.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/rootElement)
     */
    readonly rootElement: SVGSVGElement | null;
    /**
     * The **`scripts`** property of the Document interface returns a list of the <script> elements in the document. The returned object is an HTMLCollection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/scripts)
     */
    readonly scripts: HTMLCollectionOf<HTMLScriptElement>;
    /**
     * The **`scrollingElement`** read-only property of the Document interface returns a reference to the Element that scrolls the document. In standards mode, this is the root element of the document, document.documentElement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/scrollingElement)
     */
    readonly scrollingElement: Element | null;
    /**
     * The **`timeline`** readonly property of the Document interface represents the default timeline of the current document. This timeline is a special instance of DocumentTimeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/timeline)
     */
    readonly timeline: DocumentTimeline;
    /**
     * The **`document.title`** property gets or sets the current title of the document. When present, it defaults to the value of the <title>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/title)
     */
    title: string;
    /**
     * The **`Document.visibilityState`** read-only property returns the visibility of the document. It can be used to check whether the document is in the background or in a minimized window, or is otherwise not visible to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/visibilityState)
     */
    readonly visibilityState: DocumentVisibilityState;
    /**
     * The **`Document.vlinkColor`** property gets/sets the color of links that the user has visited in the document.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/vlinkColor)
     */
    vlinkColor: string;
    /**
     * **`Document.adoptNode()`** transfers a node from another document into the method's document. The adopted node and its subtree are removed from their original document (if any), and their ownerDocument is changed to the current document. The node can then be inserted into the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/adoptNode)
     */
    adoptNode<T extends Node>(node: T): T;
    /** @deprecated */
    captureEvents(): void;
    /**
     * The **`caretPositionFromPoint()`** method of the Document interface returns a CaretPosition object, containing the DOM node, along with the caret and caret's character offset within that node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/caretPositionFromPoint)
     */
    caretPositionFromPoint(x: number, y: number, options?: CaretPositionFromPointOptions): CaretPosition | null;
    /**
     * The **`caretRangeFromPoint()`** method of the Document interface returns a Range object for the document fragment under the specified coordinates.
     * @deprecated
     */
    caretRangeFromPoint(x: number, y: number): Range | null;
    /**
     * The **`Document.clear()`** method does nothing, but doesn't raise any error.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/clear)
     */
    clear(): void;
    /**
     * The **`Document.close()`** method finishes writing to a document, opened with Document.open().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/close)
     */
    close(): void;
    /**
     * The **`Document.createAttribute()`** method creates a new attribute node, and returns it. The object created is a node implementing the Attr interface. The DOM does not enforce what sort of attributes can be added to a particular element in this manner.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createAttribute)
     */
    createAttribute(localName: string): Attr;
    /**
     * The **`Document.createAttributeNS()`** method creates a new attribute node with the specified namespace URI and qualified name, and returns it. The object created is a node implementing the Attr interface. The DOM does not enforce what sort of attributes can be added to a particular element in this manner.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createAttributeNS)
     */
    createAttributeNS(namespace: string | null, qualifiedName: string): Attr;
    /**
     * **`createCDATASection()`** creates a new CDATA section node, and returns it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createCDATASection)
     */
    createCDATASection(data: string): CDATASection;
    /**
     * **`createComment()`** creates a new comment node, and returns it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createComment)
     */
    createComment(data: string): Comment;
    /**
     * Creates a new empty DocumentFragment into which DOM nodes can be added to build an offscreen DOM tree.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createDocumentFragment)
     */
    createDocumentFragment(): DocumentFragment;
    /**
     * In an HTML document, the **`document.createElement()`** method creates the HTML element specified by localName, or an HTMLUnknownElement if localName isn't recognized.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createElement)
     */
    createElement<K extends keyof HTMLElementTagNameMap>(tagName: K, options?: ElementCreationOptions): HTMLElementTagNameMap[K];
    /** @deprecated */
    createElement<K extends keyof HTMLElementDeprecatedTagNameMap>(tagName: K, options?: ElementCreationOptions): HTMLElementDeprecatedTagNameMap[K];
    createElement(tagName: string, options?: ElementCreationOptions): HTMLElement;
    /**
     * Creates an element with the specified namespace URI and qualified name.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createElementNS)
     */
    createElementNS(namespaceURI: "http://www.w3.org/1999/xhtml", qualifiedName: string): HTMLElement;
    createElementNS<K extends keyof SVGElementTagNameMap>(namespaceURI: "http://www.w3.org/2000/svg", qualifiedName: K): SVGElementTagNameMap[K];
    createElementNS(namespaceURI: "http://www.w3.org/2000/svg", qualifiedName: string): SVGElement;
    createElementNS<K extends keyof MathMLElementTagNameMap>(namespaceURI: "http://www.w3.org/1998/Math/MathML", qualifiedName: K): MathMLElementTagNameMap[K];
    createElementNS(namespaceURI: "http://www.w3.org/1998/Math/MathML", qualifiedName: string): MathMLElement;
    createElementNS(namespaceURI: string | null, qualifiedName: string, options?: ElementCreationOptions): Element;
    createElementNS(namespace: string | null, qualifiedName: string, options?: string | ElementCreationOptions): Element;
    /**
     * Creates an event of the type specified. The returned object should be first initialized and can then be passed to EventTarget.dispatchEvent.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createEvent)
     */
    createEvent(eventInterface: "AnimationEvent"): AnimationEvent;
    createEvent(eventInterface: "AnimationPlaybackEvent"): AnimationPlaybackEvent;
    createEvent(eventInterface: "AudioProcessingEvent"): AudioProcessingEvent;
    createEvent(eventInterface: "BeforeUnloadEvent"): BeforeUnloadEvent;
    createEvent(eventInterface: "BlobEvent"): BlobEvent;
    createEvent(eventInterface: "ClipboardEvent"): ClipboardEvent;
    createEvent(eventInterface: "CloseEvent"): CloseEvent;
    createEvent(eventInterface: "CommandEvent"): CommandEvent;
    createEvent(eventInterface: "CompositionEvent"): CompositionEvent;
    createEvent(eventInterface: "ContentVisibilityAutoStateChangeEvent"): ContentVisibilityAutoStateChangeEvent;
    createEvent(eventInterface: "CookieChangeEvent"): CookieChangeEvent;
    createEvent(eventInterface: "CustomEvent"): CustomEvent;
    createEvent(eventInterface: "DeviceMotionEvent"): DeviceMotionEvent;
    createEvent(eventInterface: "DeviceOrientationEvent"): DeviceOrientationEvent;
    createEvent(eventInterface: "DragEvent"): DragEvent;
    createEvent(eventInterface: "ErrorEvent"): ErrorEvent;
    createEvent(eventInterface: "Event"): Event;
    createEvent(eventInterface: "Events"): Event;
    createEvent(eventInterface: "FocusEvent"): FocusEvent;
    createEvent(eventInterface: "FontFaceSetLoadEvent"): FontFaceSetLoadEvent;
    createEvent(eventInterface: "FormDataEvent"): FormDataEvent;
    createEvent(eventInterface: "GPUUncapturedErrorEvent"): GPUUncapturedErrorEvent;
    createEvent(eventInterface: "GamepadEvent"): GamepadEvent;
    createEvent(eventInterface: "HashChangeEvent"): HashChangeEvent;
    createEvent(eventInterface: "IDBVersionChangeEvent"): IDBVersionChangeEvent;
    createEvent(eventInterface: "InputEvent"): InputEvent;
    createEvent(eventInterface: "KeyboardEvent"): KeyboardEvent;
    createEvent(eventInterface: "MIDIConnectionEvent"): MIDIConnectionEvent;
    createEvent(eventInterface: "MIDIMessageEvent"): MIDIMessageEvent;
    createEvent(eventInterface: "MediaEncryptedEvent"): MediaEncryptedEvent;
    createEvent(eventInterface: "MediaKeyMessageEvent"): MediaKeyMessageEvent;
    createEvent(eventInterface: "MediaQueryListEvent"): MediaQueryListEvent;
    createEvent(eventInterface: "MediaStreamTrackEvent"): MediaStreamTrackEvent;
    createEvent(eventInterface: "MessageEvent"): MessageEvent;
    createEvent(eventInterface: "MouseEvent"): MouseEvent;
    createEvent(eventInterface: "MouseEvents"): MouseEvent;
    createEvent(eventInterface: "NavigateEvent"): NavigateEvent;
    createEvent(eventInterface: "NavigationCurrentEntryChangeEvent"): NavigationCurrentEntryChangeEvent;
    createEvent(eventInterface: "OfflineAudioCompletionEvent"): OfflineAudioCompletionEvent;
    createEvent(eventInterface: "PageRevealEvent"): PageRevealEvent;
    createEvent(eventInterface: "PageSwapEvent"): PageSwapEvent;
    createEvent(eventInterface: "PageTransitionEvent"): PageTransitionEvent;
    createEvent(eventInterface: "PaymentMethodChangeEvent"): PaymentMethodChangeEvent;
    createEvent(eventInterface: "PaymentRequestUpdateEvent"): PaymentRequestUpdateEvent;
    createEvent(eventInterface: "PictureInPictureEvent"): PictureInPictureEvent;
    createEvent(eventInterface: "PointerEvent"): PointerEvent;
    createEvent(eventInterface: "PopStateEvent"): PopStateEvent;
    createEvent(eventInterface: "ProgressEvent"): ProgressEvent;
    createEvent(eventInterface: "PromiseRejectionEvent"): PromiseRejectionEvent;
    createEvent(eventInterface: "RTCDTMFToneChangeEvent"): RTCDTMFToneChangeEvent;
    createEvent(eventInterface: "RTCDataChannelEvent"): RTCDataChannelEvent;
    createEvent(eventInterface: "RTCErrorEvent"): RTCErrorEvent;
    createEvent(eventInterface: "RTCPeerConnectionIceErrorEvent"): RTCPeerConnectionIceErrorEvent;
    createEvent(eventInterface: "RTCPeerConnectionIceEvent"): RTCPeerConnectionIceEvent;
    createEvent(eventInterface: "RTCTrackEvent"): RTCTrackEvent;
    createEvent(eventInterface: "SecurityPolicyViolationEvent"): SecurityPolicyViolationEvent;
    createEvent(eventInterface: "SpeechRecognitionErrorEvent"): SpeechRecognitionErrorEvent;
    createEvent(eventInterface: "SpeechRecognitionEvent"): SpeechRecognitionEvent;
    createEvent(eventInterface: "SpeechSynthesisErrorEvent"): SpeechSynthesisErrorEvent;
    createEvent(eventInterface: "SpeechSynthesisEvent"): SpeechSynthesisEvent;
    createEvent(eventInterface: "StorageEvent"): StorageEvent;
    createEvent(eventInterface: "SubmitEvent"): SubmitEvent;
    createEvent(eventInterface: "TaskPriorityChangeEvent"): TaskPriorityChangeEvent;
    createEvent(eventInterface: "TextEvent"): TextEvent;
    createEvent(eventInterface: "ToggleEvent"): ToggleEvent;
    createEvent(eventInterface: "TouchEvent"): TouchEvent;
    createEvent(eventInterface: "TrackEvent"): TrackEvent;
    createEvent(eventInterface: "TransitionEvent"): TransitionEvent;
    createEvent(eventInterface: "UIEvent"): UIEvent;
    createEvent(eventInterface: "UIEvents"): UIEvent;
    createEvent(eventInterface: "WebGLContextEvent"): WebGLContextEvent;
    createEvent(eventInterface: "WheelEvent"): WheelEvent;
    createEvent(eventInterface: string): Event;
    /**
     * The **`Document.createNodeIterator()`** method returns a new NodeIterator object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createNodeIterator)
     */
    createNodeIterator(root: Node, whatToShow?: number, filter?: NodeFilter | null): NodeIterator;
    /**
     * **`createProcessingInstruction()`** generates a new processing instruction node and returns it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createProcessingInstruction)
     */
    createProcessingInstruction(target: string, data: string): ProcessingInstruction;
    /**
     * The **`Document.createRange()`** method returns a new Range object whose start and end are offset 0 of the Document object on which it was called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createRange)
     */
    createRange(): Range;
    /**
     * Creates a new Text node. This method can be used to escape HTML characters.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createTextNode)
     */
    createTextNode(data: string): Text;
    /**
     * The **`Document.createTreeWalker()`** creator method returns a newly created TreeWalker object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/createTreeWalker)
     */
    createTreeWalker(root: Node, whatToShow?: number, filter?: NodeFilter | null): TreeWalker;
    /**
     * The **`execCommand`** method implements multiple different commands. Some of them provide access to the clipboard, while others are for editing form inputs, contenteditable elements or entire documents (when switched to design mode).
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/execCommand)
     */
    execCommand(commandId: string, showUI?: boolean, value?: string): boolean;
    /**
     * The Document method **`exitFullscreen()`** requests that the element on this document which is currently being presented in fullscreen mode be taken out of fullscreen mode, restoring the previous state of the screen. This usually reverses the effects of a previous call to Element.requestFullscreen().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/exitFullscreen)
     */
    exitFullscreen(): Promise<void>;
    /**
     * The **`exitPictureInPicture()`** method of the Document interface requests that a video contained in this document, which is currently floating, be taken out of picture-in-picture mode, restoring the previous state of the screen. This usually reverses the effects of a previous call to HTMLVideoElement.requestPictureInPicture().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/exitPictureInPicture)
     */
    exitPictureInPicture(): Promise<void>;
    /**
     * The **`exitPointerLock()`** method of the Document interface asynchronously releases a pointer lock previously requested through Element.requestPointerLock.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/exitPointerLock)
     */
    exitPointerLock(): void;
    /** The **`getElementById()`** method of the Document interface returns an Element object representing the element whose id property matches the specified string. Since element IDs are required to be unique if specified, they're a useful way to get access to a specific element quickly. */
    getElementById(elementId: string): HTMLElement | null;
    /**
     * The **`getElementsByClassName`** method of Document interface returns an array-like object of all child elements which have all of the given class name(s).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getElementsByClassName)
     */
    getElementsByClassName(classNames: string): HTMLCollectionOf<Element>;
    /**
     * The **`getElementsByName()`** method of the Document object returns a NodeList Collection of elements with a given name attribute in the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getElementsByName)
     */
    getElementsByName(elementName: string): NodeListOf<HTMLElement>;
    /**
     * The **`getElementsByTagName`** method of Document interface returns an HTMLCollection of elements with the given tag name.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getElementsByTagName)
     */
    getElementsByTagName<K extends keyof HTMLElementTagNameMap>(qualifiedName: K): HTMLCollectionOf<HTMLElementTagNameMap[K]>;
    getElementsByTagName<K extends keyof SVGElementTagNameMap>(qualifiedName: K): HTMLCollectionOf<SVGElementTagNameMap[K]>;
    getElementsByTagName<K extends keyof MathMLElementTagNameMap>(qualifiedName: K): HTMLCollectionOf<MathMLElementTagNameMap[K]>;
    /** @deprecated */
    getElementsByTagName<K extends keyof HTMLElementDeprecatedTagNameMap>(qualifiedName: K): HTMLCollectionOf<HTMLElementDeprecatedTagNameMap[K]>;
    getElementsByTagName(qualifiedName: string): HTMLCollectionOf<Element>;
    /**
     * Returns a list of elements with the given tag name belonging to the given namespace. The complete document is searched, including the root node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getElementsByTagNameNS)
     */
    getElementsByTagNameNS(namespaceURI: "http://www.w3.org/1999/xhtml", localName: string): HTMLCollectionOf<HTMLElement>;
    getElementsByTagNameNS(namespaceURI: "http://www.w3.org/2000/svg", localName: string): HTMLCollectionOf<SVGElement>;
    getElementsByTagNameNS(namespaceURI: "http://www.w3.org/1998/Math/MathML", localName: string): HTMLCollectionOf<MathMLElement>;
    getElementsByTagNameNS(namespace: string | null, localName: string): HTMLCollectionOf<Element>;
    /**
     * The **`getSelection()`** method of the Document interface returns the Selection object associated with this document, representing the range of text selected by the user, or the current position of the caret.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getSelection)
     */
    getSelection(): Selection | null;
    /**
     * The **`hasFocus()`** method of the Document interface returns a boolean value indicating whether the document or any element inside the document has focus. This method can be used to determine whether the active element in a document has focus.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/hasFocus)
     */
    hasFocus(): boolean;
    /**
     * The **`hasStorageAccess()`** method of the Document interface returns a Promise that resolves with a boolean value indicating whether the document has access to third-party, unpartitioned cookies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/hasStorageAccess)
     */
    hasStorageAccess(): Promise<boolean>;
    /**
     * The **`importNode()`** method of the Document interface creates a copy of a Node or DocumentFragment from another document, to be inserted into the current document later.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/importNode)
     */
    importNode<T extends Node>(node: T, options?: boolean | ImportNodeOptions): T;
    /**
     * The **`Document.open()`** method opens a document for writing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/open)
     */
    open(unused1?: string, unused2?: string): Document;
    open(url: string | URL, name: string, features: string): WindowProxy | null;
    /**
     * The **`Document.queryCommandEnabled()`** method reports whether or not the specified editor command is enabled by the browser.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/queryCommandEnabled)
     */
    queryCommandEnabled(commandId: string): boolean;
    /** @deprecated */
    queryCommandIndeterm(commandId: string): boolean;
    /**
     * The **`queryCommandState()`** method will tell you if the current selection has a certain Document.execCommand() command applied.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/queryCommandState)
     */
    queryCommandState(commandId: string): boolean;
    /**
     * The **`Document.queryCommandSupported()`** method reports whether or not the specified editor command is supported by the browser.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/queryCommandSupported)
     */
    queryCommandSupported(commandId: string): boolean;
    /** @deprecated */
    queryCommandValue(commandId: string): string;
    /** @deprecated */
    releaseEvents(): void;
    /**
     * The **`requestStorageAccess()`** method of the Document interface allows content loaded in a third-party context (i.e., embedded in an <iframe>) to request access to third-party cookies and unpartitioned state. This is relevant to user agents that, by default, block access to third-party, unpartitioned cookies to improve privacy (e.g., to prevent tracking), and is part of the Storage Access API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/requestStorageAccess)
     */
    requestStorageAccess(): Promise<void>;
    /**
     * The **`startViewTransition()`** method of the Document interface starts a new same-document (SPA) view transition and returns a ViewTransition object to represent it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/startViewTransition)
     */
    startViewTransition(callbackOptions?: ViewTransitionUpdateCallback | StartViewTransitionOptions): ViewTransition;
    /**
     * The **`write()`** method of the Document interface writes text in one or more TrustedHTML or string parameters to a document stream opened by document.open().
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/write)
     */
    write(...text: string[]): void;
    /**
     * The **`writeln()`** method of the Document interface writes text in one or more TrustedHTML or string parameters to a document stream opened by document.open(), followed by a newline character.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/writeln)
     */
    writeln(...text: string[]): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/textContent) */
    get textContent(): null;
    addEventListener<K extends keyof DocumentEventMap>(type: K, listener: (this: Document, ev: DocumentEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof DocumentEventMap>(type: K, listener: (this: Document, ev: DocumentEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Document: {
    prototype: Document;
    new(): Document;
    /**
     * The **`parseHTMLUnsafe()`** static method of the Document object is used to parse HTML input, optionally filtering unwanted HTML elements and attributes, in order to create a new Document instance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/parseHTMLUnsafe_static)
     */
    parseHTMLUnsafe(html: string): Document;
};

/**
 * The **`DocumentFragment`** interface represents a minimal document object that has no parent.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DocumentFragment)
 */
interface DocumentFragment extends Node, NonElementParentNode, ParentNode {
    readonly ownerDocument: Document;
    /** The **`getElementById()`** method of the DocumentFragment returns an Element object representing the element whose id property matches the specified string. Since element IDs are required to be unique if specified, they're a useful way to get access to a specific element quickly. */
    getElementById(elementId: string): HTMLElement | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/textContent) */
    get textContent(): string;
    set textContent(value: string | null);
}

declare var DocumentFragment: {
    prototype: DocumentFragment;
    new(): DocumentFragment;
};

interface DocumentOrShadowRoot {
    /**
     * Returns the deepest element in the document through which or to which key events are being routed. This is, roughly speaking, the focused element in the document.
     *
     * For the purposes of this API, when a child browsing context is focused, its container is focused in the parent browsing context. For example, if the user moves the focus to a text control in an iframe, the iframe is the element returned by the activeElement API in the iframe's node document.
     *
     * Similarly, when the focused element is in a different node tree than documentOrShadowRoot, the element returned will be the host that's located in the same node tree as documentOrShadowRoot if documentOrShadowRoot is a shadow-including inclusive ancestor of the focused element, and null if not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/activeElement)
     */
    readonly activeElement: Element | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/adoptedStyleSheets) */
    adoptedStyleSheets: CSSStyleSheet[];
    readonly customElementRegistry: CustomElementRegistry | null;
    /**
     * Returns document's fullscreen element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fullscreenElement)
     */
    readonly fullscreenElement: Element | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/pictureInPictureElement) */
    readonly pictureInPictureElement: Element | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/pointerLockElement) */
    readonly pointerLockElement: Element | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/styleSheets) */
    readonly styleSheets: StyleSheetList;
    elementFromPoint(x: number, y: number): Element | null;
    elementsFromPoint(x: number, y: number): Element[];
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getAnimations) */
    getAnimations(): Animation[];
}

/**
 * The **`DocumentTimeline`** interface of the Web Animations API represents animation timelines, including the default document timeline (accessed via Document.timeline).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DocumentTimeline)
 */
interface DocumentTimeline extends AnimationTimeline {
}

declare var DocumentTimeline: {
    prototype: DocumentTimeline;
    new(options?: DocumentTimelineOptions): DocumentTimeline;
};

/**
 * The **`DocumentType`** interface represents a Node containing a doctype.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DocumentType)
 */
interface DocumentType extends Node, ChildNode {
    /**
     * The read-only **`name`** property of the DocumentType returns the type of the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DocumentType/name)
     */
    readonly name: string;
    readonly ownerDocument: Document;
    /**
     * The read-only **`publicId`** property of the DocumentType returns a formal identifier of the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DocumentType/publicId)
     */
    readonly publicId: string;
    /**
     * The read-only **`systemId`** property of the DocumentType returns the URL of the associated DTD.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DocumentType/systemId)
     */
    readonly systemId: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/textContent) */
    get textContent(): null;
}

declare var DocumentType: {
    prototype: DocumentType;
    new(): DocumentType;
};

/**
 * The **`DragEvent`** interface is a DOM event that represents a drag and drop interaction. The user initiates a drag by placing a pointer device (such as a mouse) on the touch surface and then dragging the pointer to a new location (such as another DOM element). Applications are free to interpret a drag and drop interaction in an application-specific way.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DragEvent)
 */
interface DragEvent extends MouseEvent {
    /**
     * The **`DragEvent.dataTransfer`** read-only property holds the drag operation's data (as a DataTransfer object).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DragEvent/dataTransfer)
     */
    readonly dataTransfer: DataTransfer | null;
}

declare var DragEvent: {
    prototype: DragEvent;
    new(type: string, eventInitDict?: DragEventInit): DragEvent;
};

/**
 * The **`DynamicsCompressorNode`** interface provides a compression effect, which lowers the volume of the loudest parts of the signal in order to help prevent clipping and distortion that can occur when multiple sounds are played and multiplexed together at once. This is often used in musical production and game audio. DynamicsCompressorNode is an AudioNode that has exactly one input and one output.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode)
 */
interface DynamicsCompressorNode extends AudioNode {
    /**
     * The **`attack`** property of the DynamicsCompressorNode interface is a k-rate AudioParam representing the amount of time, in seconds, required to reduce the gain by 10 dB. It defines how quickly the signal is adapted when its volume is increased.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode/attack)
     */
    readonly attack: AudioParam;
    /**
     * The **`knee`** property of the DynamicsCompressorNode interface is a k-rate AudioParam containing a decibel value representing the range above the threshold where the curve smoothly transitions to the compressed portion.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode/knee)
     */
    readonly knee: AudioParam;
    /**
     * The **`ratio`** property of the DynamicsCompressorNode interface Is a k-rate AudioParam representing the amount of change, in dB, needed in the input for a 1 dB change in the output.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode/ratio)
     */
    readonly ratio: AudioParam;
    /**
     * The **`reduction`** read-only property of the DynamicsCompressorNode interface is a float representing the amount of gain reduction currently applied by the compressor to the signal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode/reduction)
     */
    readonly reduction: number;
    /**
     * The **`release`** property of the DynamicsCompressorNode interface Is a k-rate AudioParam representing the amount of time, in seconds, required to increase the gain by 10 dB. It defines how quick the signal is adapted when its volume is reduced.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode/release)
     */
    readonly release: AudioParam;
    /**
     * The **`threshold`** property of the DynamicsCompressorNode interface is a k-rate AudioParam representing the decibel value above which the compression will start taking effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/DynamicsCompressorNode/threshold)
     */
    readonly threshold: AudioParam;
}

declare var DynamicsCompressorNode: {
    prototype: DynamicsCompressorNode;
    new(context: BaseAudioContext, options?: DynamicsCompressorOptions): DynamicsCompressorNode;
};

/**
 * The **`EXT_blend_minmax`** extension is part of the WebGL API and extends blending capabilities by adding two new blend equations: the minimum or maximum color components of the source and destination colors.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_blend_minmax)
 */
interface EXT_blend_minmax {
    readonly MIN_EXT: 0x8007;
    readonly MAX_EXT: 0x8008;
}

/**
 * The **`EXT_color_buffer_float`** extension is part of WebGL and adds the ability to render a variety of floating point formats.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_color_buffer_float)
 */
interface EXT_color_buffer_float {
}

/**
 * The **`EXT_color_buffer_half_float`** extension is part of the WebGL API and adds the ability to render to 16-bit floating-point color buffers.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_color_buffer_half_float)
 */
interface EXT_color_buffer_half_float {
    readonly RGBA16F_EXT: 0x881A;
    readonly RGB16F_EXT: 0x881B;
    readonly FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE_EXT: 0x8211;
    readonly UNSIGNED_NORMALIZED_EXT: 0x8C17;
}

/**
 * The WebGL API's **`EXT_float_blend`** extension allows blending and draw buffers with 32-bit floating-point components.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_float_blend)
 */
interface EXT_float_blend {
}

/**
 * The **`EXT_frag_depth`** extension is part of the WebGL API and enables to set a depth value of a fragment from within the fragment shader.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_frag_depth)
 */
interface EXT_frag_depth {
}

/**
 * The **`EXT_sRGB`** extension is part of the WebGL API and adds sRGB support to textures and framebuffer objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_sRGB)
 */
interface EXT_sRGB {
    readonly SRGB_EXT: 0x8C40;
    readonly SRGB_ALPHA_EXT: 0x8C42;
    readonly SRGB8_ALPHA8_EXT: 0x8C43;
    readonly FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING_EXT: 0x8210;
}

/**
 * The **`EXT_shader_texture_lod`** extension is part of the WebGL API and adds additional texture functions to the OpenGL ES Shading Language which provide the shader writer with explicit control of LOD (Level of detail).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_shader_texture_lod)
 */
interface EXT_shader_texture_lod {
}

/**
 * The **`EXT_texture_compression_bptc`** extension is part of the WebGL API and exposes 4 BPTC compressed texture formats. These compression formats are called BC7 and BC6H in Microsoft's DirectX API.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_texture_compression_bptc)
 */
interface EXT_texture_compression_bptc {
    readonly COMPRESSED_RGBA_BPTC_UNORM_EXT: 0x8E8C;
    readonly COMPRESSED_SRGB_ALPHA_BPTC_UNORM_EXT: 0x8E8D;
    readonly COMPRESSED_RGB_BPTC_SIGNED_FLOAT_EXT: 0x8E8E;
    readonly COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_EXT: 0x8E8F;
}

/**
 * The **`EXT_texture_compression_rgtc`** extension is part of the WebGL API and exposes 4 RGTC compressed texture formats. RGTC is a block-based texture compression format suited for unsigned and signed red and red-green textures (Red-Green Texture Compression).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_texture_compression_rgtc)
 */
interface EXT_texture_compression_rgtc {
    readonly COMPRESSED_RED_RGTC1_EXT: 0x8DBB;
    readonly COMPRESSED_SIGNED_RED_RGTC1_EXT: 0x8DBC;
    readonly COMPRESSED_RED_GREEN_RGTC2_EXT: 0x8DBD;
    readonly COMPRESSED_SIGNED_RED_GREEN_RGTC2_EXT: 0x8DBE;
}

/**
 * The **`EXT_texture_filter_anisotropic`** extension is part of the WebGL API and exposes two constants for anisotropic filtering (AF).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_texture_filter_anisotropic)
 */
interface EXT_texture_filter_anisotropic {
    readonly TEXTURE_MAX_ANISOTROPY_EXT: 0x84FE;
    readonly MAX_TEXTURE_MAX_ANISOTROPY_EXT: 0x84FF;
}

/**
 * The **`EXT_texture_norm16`** extension is part of the WebGL API and provides a set of new 16-bit signed normalized and unsigned normalized formats (fixed-point texture, renderbuffer and texture buffer).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EXT_texture_norm16)
 */
interface EXT_texture_norm16 {
    readonly R16_EXT: 0x822A;
    readonly RG16_EXT: 0x822C;
    readonly RGB16_EXT: 0x8054;
    readonly RGBA16_EXT: 0x805B;
    readonly R16_SNORM_EXT: 0x8F98;
    readonly RG16_SNORM_EXT: 0x8F99;
    readonly RGB16_SNORM_EXT: 0x8F9A;
    readonly RGBA16_SNORM_EXT: 0x8F9B;
}

interface ElementEventMap {
    "fullscreenchange": Event;
    "fullscreenerror": Event;
}

/**
 * **`Element`** is the most general base class from which all element objects (i.e., objects that represent elements) in a Document inherit. It only has methods and properties common to all kinds of elements. More specific classes inherit from Element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element)
 */
interface Element extends Node, ARIAMixin, Animatable, ChildNode, NonDocumentTypeChildNode, ParentNode, Slottable {
    /**
     * The **`Element.attributes`** property returns a live collection of all attribute nodes registered to the specified node. It is a NamedNodeMap, not an Array, so it has no Array methods and the Attr nodes' indexes may differ among browsers. To be more specific, attributes is a key/value pair of strings that represents any information regarding that attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/attributes)
     */
    readonly attributes: NamedNodeMap;
    /**
     * The read-only **`classList`** property of the Element interface contains a live DOMTokenList collection representing the class attribute of the element. This can then be used to manipulate the class list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/classList)
     */
    get classList(): DOMTokenList;
    set classList(value: string);
    /**
     * The **`className`** property of the Element interface gets and sets the value of the class attribute of the specified element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/className)
     */
    className: string;
    /**
     * The **`clientHeight`** read-only property of the Element interface is zero for elements with no CSS or inline layout boxes; otherwise, it's the inner height of an element in pixels. It includes padding but excludes borders, margins, and horizontal scrollbars (if present).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/clientHeight)
     */
    readonly clientHeight: number;
    /**
     * The **`clientLeft`** read-only property of the Element interface returns the width of the left border of an element in pixels. It includes the width of the vertical scrollbar if the text direction of the element is right-to-left and if there is an overflow causing a left vertical scrollbar to be rendered. clientLeft does not include the left margin or the left padding.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/clientLeft)
     */
    readonly clientLeft: number;
    /**
     * The **`clientTop`** read-only property of the Element interface returns the width of the top border of an element in pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/clientTop)
     */
    readonly clientTop: number;
    /**
     * The **`clientWidth`** read-only property of the Element interface is zero for inline elements and elements with no CSS; otherwise, it's the inner width of an element in pixels. It includes padding but excludes borders, margins, and vertical scrollbars (if present).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/clientWidth)
     */
    readonly clientWidth: number;
    /**
     * The **`currentCSSZoom`** read-only property of the Element interface provides the "effective" CSS zoom of an element, taking into account the zoom applied to the element and all its parent elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/currentCSSZoom)
     */
    readonly currentCSSZoom: number;
    readonly customElementRegistry: CustomElementRegistry | null;
    /**
     * The **`id`** property of the Element interface represents the element's identifier, reflecting the id global attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/id)
     */
    id: string;
    /**
     * The **`innerHTML`** property of the Element interface gets or sets the HTML or XML markup contained within the element, omitting any shadow roots in both cases.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/innerHTML)
     */
    innerHTML: string;
    /**
     * The **`Element.localName`** read-only property returns the local part of the qualified name of an element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/localName)
     */
    readonly localName: string;
    /**
     * The **`Element.namespaceURI`** read-only property returns the namespace URI of the element, or null if the element is not in a namespace.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/namespaceURI)
     */
    readonly namespaceURI: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/fullscreenchange_event) */
    onfullscreenchange: ((this: Element, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/fullscreenerror_event) */
    onfullscreenerror: ((this: Element, ev: Event) => any) | null;
    /**
     * The **`outerHTML`** attribute of the Element interface gets or sets the HTML or XML markup of the element and its descendants, omitting any shadow roots in both cases.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/outerHTML)
     */
    outerHTML: string;
    readonly ownerDocument: Document;
    /**
     * The read-only **`part`** property of the Element interface contains a DOMTokenList object representing the part identifier(s) of the element. It reflects the element's part content attribute. These can be used to style parts of a shadow DOM, via the ::part pseudo-element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/part)
     */
    get part(): DOMTokenList;
    set part(value: string);
    /**
     * The **`Element.prefix`** read-only property returns the namespace prefix of the specified element, or null if no prefix is specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/prefix)
     */
    readonly prefix: string | null;
    /**
     * The **`scrollHeight`** read-only property of the Element interface is a measurement of the height of an element's content, including content not visible on the screen due to overflow.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollHeight)
     */
    readonly scrollHeight: number;
    /**
     * The **`scrollLeft`** property of the Element interface gets or sets the number of pixels by which an element's content is scrolled from its left edge. This value is subpixel precise in modern browsers, meaning that it isn't necessarily a whole number.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollLeft)
     */
    scrollLeft: number;
    /**
     * The **`scrollTop`** property of the Element interface gets or sets the number of pixels by which an element's content is scrolled from its top edge. This value is subpixel precise in modern browsers, meaning that it isn't necessarily a whole number.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollTop)
     */
    scrollTop: number;
    /**
     * The **`scrollWidth`** read-only property of the Element interface is a measurement of the width of an element's content, including content not visible on the screen due to overflow.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollWidth)
     */
    readonly scrollWidth: number;
    /**
     * The **`Element.shadowRoot`** read-only property represents the shadow root hosted by the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/shadowRoot)
     */
    readonly shadowRoot: ShadowRoot | null;
    /**
     * The **`slot`** property of the Element interface returns the name of the shadow DOM slot the element is inserted in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/slot)
     */
    slot: string;
    /**
     * The **`tagName`** read-only property of the Element interface returns the tag name of the element on which it's called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/tagName)
     */
    readonly tagName: string;
    /**
     * The **`Element.attachShadow()`** method attaches a shadow DOM tree to the specified element and returns a reference to its ShadowRoot.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/attachShadow)
     */
    attachShadow(init: ShadowRootInit): ShadowRoot;
    /**
     * The **`checkVisibility()`** method of the Element interface checks whether the element is visible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/checkVisibility)
     */
    checkVisibility(options?: CheckVisibilityOptions): boolean;
    /**
     * The **`closest()`** method of the Element interface traverses the element and its parents (heading toward the document root) until it finds a node that matches the specified CSS selector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/closest)
     */
    closest<K extends keyof HTMLElementTagNameMap>(selector: K): HTMLElementTagNameMap[K] | null;
    closest<K extends keyof SVGElementTagNameMap>(selector: K): SVGElementTagNameMap[K] | null;
    closest<K extends keyof MathMLElementTagNameMap>(selector: K): MathMLElementTagNameMap[K] | null;
    closest<E extends Element = Element>(selectors: string): E | null;
    /**
     * The **`computedStyleMap()`** method of the Element interface returns a StylePropertyMapReadOnly interface which provides a read-only representation of a CSS declaration block that is an alternative to CSSStyleDeclaration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/computedStyleMap)
     */
    computedStyleMap(): StylePropertyMapReadOnly;
    /**
     * The **`getAttribute()`** method of the Element interface returns the value of a specified attribute on the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getAttribute)
     */
    getAttribute(qualifiedName: string): string | null;
    /**
     * The **`getAttributeNS()`** method of the Element interface returns the string value of the attribute with the specified namespace and name. If the named attribute does not exist, the value returned will either be null or "" (the empty string); see Notes for details.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getAttributeNS)
     */
    getAttributeNS(namespace: string | null, localName: string): string | null;
    /**
     * The **`getAttributeNames()`** method of the Element interface returns the attribute names of the element as an Array of strings. If the element has no attributes it returns an empty array.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getAttributeNames)
     */
    getAttributeNames(): string[];
    /**
     * Returns the specified attribute of the specified element, as an Attr node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getAttributeNode)
     */
    getAttributeNode(qualifiedName: string): Attr | null;
    /**
     * The **`getAttributeNodeNS()`** method of the Element interface returns the namespaced Attr node of an element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getAttributeNodeNS)
     */
    getAttributeNodeNS(namespace: string | null, localName: string): Attr | null;
    /**
     * The **`Element.getBoundingClientRect()`** method returns a DOMRect object providing information about the size of an element and its position relative to the viewport.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getBoundingClientRect)
     */
    getBoundingClientRect(): DOMRect;
    /**
     * The **`getClientRects()`** method of the Element interface returns a collection of DOMRect objects that indicate the bounding rectangles for each CSS border box in a client.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getClientRects)
     */
    getClientRects(): DOMRectList;
    /**
     * The Element method **`getElementsByClassName()`** returns a live HTMLCollection which contains every descendant element which has the specified class name or names.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getElementsByClassName)
     */
    getElementsByClassName(classNames: string): HTMLCollectionOf<Element>;
    /**
     * The **`Element.getElementsByTagName()`** method returns a live HTMLCollection of elements with the given tag name.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getElementsByTagName)
     */
    getElementsByTagName<K extends keyof HTMLElementTagNameMap>(qualifiedName: K): HTMLCollectionOf<HTMLElementTagNameMap[K]>;
    getElementsByTagName<K extends keyof SVGElementTagNameMap>(qualifiedName: K): HTMLCollectionOf<SVGElementTagNameMap[K]>;
    getElementsByTagName<K extends keyof MathMLElementTagNameMap>(qualifiedName: K): HTMLCollectionOf<MathMLElementTagNameMap[K]>;
    /** @deprecated */
    getElementsByTagName<K extends keyof HTMLElementDeprecatedTagNameMap>(qualifiedName: K): HTMLCollectionOf<HTMLElementDeprecatedTagNameMap[K]>;
    getElementsByTagName(qualifiedName: string): HTMLCollectionOf<Element>;
    /**
     * The **`Element.getElementsByTagNameNS()`** method returns a live HTMLCollection of elements with the given tag name belonging to the given namespace. It is similar to Document.getElementsByTagNameNS, except that its search is restricted to descendants of the specified element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getElementsByTagNameNS)
     */
    getElementsByTagNameNS(namespaceURI: "http://www.w3.org/1999/xhtml", localName: string): HTMLCollectionOf<HTMLElement>;
    getElementsByTagNameNS(namespaceURI: "http://www.w3.org/2000/svg", localName: string): HTMLCollectionOf<SVGElement>;
    getElementsByTagNameNS(namespaceURI: "http://www.w3.org/1998/Math/MathML", localName: string): HTMLCollectionOf<MathMLElement>;
    getElementsByTagNameNS(namespace: string | null, localName: string): HTMLCollectionOf<Element>;
    /**
     * The **`getHTML()`** method of the Element interface is used to serialize an element's DOM to an HTML string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/getHTML)
     */
    getHTML(options?: GetHTMLOptions): string;
    /**
     * The **`Element.hasAttribute()`** method returns a Boolean value indicating whether the specified element has the specified attribute or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/hasAttribute)
     */
    hasAttribute(qualifiedName: string): boolean;
    /**
     * The **`hasAttributeNS()`** method of the Element interface returns a boolean value indicating whether the current element has the specified attribute with the specified namespace.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/hasAttributeNS)
     */
    hasAttributeNS(namespace: string | null, localName: string): boolean;
    /**
     * The **`hasAttributes()`** method of the Element interface returns a boolean value indicating whether the current element has any attributes or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/hasAttributes)
     */
    hasAttributes(): boolean;
    /**
     * The **`hasPointerCapture()`** method of the Element interface checks whether the element on which it is invoked has pointer capture for the pointer identified by the given pointer ID.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/hasPointerCapture)
     */
    hasPointerCapture(pointerId: number): boolean;
    /**
     * The **`insertAdjacentElement()`** method of the Element interface inserts a given element node at a given position relative to the element it is invoked upon.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/insertAdjacentElement)
     */
    insertAdjacentElement(where: InsertPosition, element: Element): Element | null;
    /**
     * The **`insertAdjacentHTML()`** method of the Element interface parses the specified input as HTML or XML and inserts the resulting nodes into the DOM tree at a specified position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/insertAdjacentHTML)
     */
    insertAdjacentHTML(position: InsertPosition, string: string): void;
    /**
     * The **`insertAdjacentText()`** method of the Element interface, given a relative position and a string, inserts a new text node at the given position relative to the element it is called from.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/insertAdjacentText)
     */
    insertAdjacentText(where: InsertPosition, data: string): void;
    /**
     * The **`matches()`** method of the Element interface tests whether the element would be selected by the specified CSS selector.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/matches)
     */
    matches<K extends keyof HTMLElementTagNameMap>(selectors: K): this is HTMLElementTagNameMap[K];
    matches<K extends keyof SVGElementTagNameMap>(selectors: K): this is SVGElementTagNameMap[K];
    matches<K extends keyof MathMLElementTagNameMap>(selectors: K): this is MathMLElementTagNameMap[K];
    matches(selectors: string): boolean;
    /**
     * The **`releasePointerCapture()`** method of the Element interface releases (stops) pointer capture that was previously set for a specific (PointerEvent) pointer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/releasePointerCapture)
     */
    releasePointerCapture(pointerId: number): void;
    /**
     * The Element method **`removeAttribute()`** removes the attribute with the specified name from the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/removeAttribute)
     */
    removeAttribute(qualifiedName: string): void;
    /**
     * The **`removeAttributeNS()`** method of the Element interface removes the specified attribute with the specified namespace from an element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/removeAttributeNS)
     */
    removeAttributeNS(namespace: string | null, localName: string): void;
    /**
     * The **`removeAttributeNode()`** method of the Element interface removes the specified Attr node from the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/removeAttributeNode)
     */
    removeAttributeNode(attr: Attr): Attr;
    /**
     * The **`Element.requestFullscreen()`** method issues an asynchronous request to make the element be displayed in fullscreen mode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/requestFullscreen)
     */
    requestFullscreen(options?: FullscreenOptions): Promise<void>;
    /**
     * The **`requestPointerLock()`** method of the Element interface lets you asynchronously ask for the pointer to be locked on the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/requestPointerLock)
     */
    requestPointerLock(options?: PointerLockOptions): Promise<void>;
    /**
     * The **`scroll()`** method of the Element interface scrolls the element to a particular set of coordinates inside a given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scroll)
     */
    scroll(options?: ScrollToOptions): void;
    scroll(x: number, y: number): void;
    /**
     * The **`scrollBy()`** method of the Element interface scrolls an element by the given amount.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollBy)
     */
    scrollBy(options?: ScrollToOptions): void;
    scrollBy(x: number, y: number): void;
    /**
     * The Element interface's **`scrollIntoView()`** method scrolls the element's ancestor containers such that the element on which scrollIntoView() is called is visible to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollIntoView)
     */
    scrollIntoView(arg?: boolean | ScrollIntoViewOptions): void;
    /**
     * The **`scrollTo()`** method of the Element interface scrolls to a particular set of coordinates inside a given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/scrollTo)
     */
    scrollTo(options?: ScrollToOptions): void;
    scrollTo(x: number, y: number): void;
    /**
     * The **`setAttribute()`** method of the Element interface sets the value of an attribute on the specified element. If the attribute already exists, the value is updated; otherwise a new attribute is added with the specified name and value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/setAttribute)
     */
    setAttribute(qualifiedName: string, value: string): void;
    /**
     * The **`setAttributeNS()`** method of the Element interface adds a new attribute or changes the value of an attribute with the given namespace and name.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/setAttributeNS)
     */
    setAttributeNS(namespace: string | null, qualifiedName: string, value: string): void;
    /**
     * The **`setAttributeNode()`** method of the Element interface adds a new Attr node to the specified element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/setAttributeNode)
     */
    setAttributeNode(attr: Attr): Attr | null;
    /**
     * The **`setAttributeNodeNS()`** method of the Element interface adds a new namespaced Attr node to an element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/setAttributeNodeNS)
     */
    setAttributeNodeNS(attr: Attr): Attr | null;
    /**
     * The **`setHTMLUnsafe()`** method of the Element interface is used to parse HTML input into a DocumentFragment, optionally filtering out unwanted elements and attributes, and those that don't belong in the context, and then using it to replace the element's subtree in the DOM.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/setHTMLUnsafe)
     */
    setHTMLUnsafe(html: string): void;
    /**
     * The **`setPointerCapture()`** method of the Element interface is used to designate a specific element as the capture target of future pointer events. Subsequent events for the pointer will be targeted at the capture element until capture is released (via Element.releasePointerCapture() or the pointerup event is fired).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/setPointerCapture)
     */
    setPointerCapture(pointerId: number): void;
    /**
     * The **`toggleAttribute()`** method of the Element interface toggles a Boolean attribute (removing it if it is present and adding it if it is not present) on the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/toggleAttribute)
     */
    toggleAttribute(qualifiedName: string, force?: boolean): boolean;
    /**
     * @deprecated This is a legacy alias of `matches`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/matches)
     */
    webkitMatchesSelector(selectors: string): boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/textContent) */
    get textContent(): string;
    set textContent(value: string | null);
    addEventListener<K extends keyof ElementEventMap>(type: K, listener: (this: Element, ev: ElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ElementEventMap>(type: K, listener: (this: Element, ev: ElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Element: {
    prototype: Element;
    new(): Element;
};

interface ElementCSSInlineStyle {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/attributeStyleMap) */
    readonly attributeStyleMap: StylePropertyMap;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/style) */
    get style(): CSSStyleDeclaration;
    set style(cssText: string);
}

interface ElementContentEditable {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/contentEditable) */
    contentEditable: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/enterKeyHint) */
    enterKeyHint: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/inputMode) */
    inputMode: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/isContentEditable) */
    readonly isContentEditable: boolean;
}

/**
 * The **`ElementInternals`** interface of the Document Object Model gives web developers a way to allow custom elements to fully participate in HTML forms. It provides utilities for working with these elements in the same way you would work with any standard HTML form element, and also exposes the Accessibility Object Model to the element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals)
 */
interface ElementInternals extends ARIAMixin {
    /**
     * The **`form`** read-only property of the ElementInternals interface returns the HTMLFormElement associated with this element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`labels`** read-only property of the ElementInternals interface returns the labels associated with the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/labels)
     */
    readonly labels: NodeList;
    /**
     * The **`shadowRoot`** read-only property of the ElementInternals interface returns the ShadowRoot for this element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/shadowRoot)
     */
    readonly shadowRoot: ShadowRoot | null;
    /**
     * The **`states`** read-only property of the ElementInternals interface returns a CustomStateSet representing the possible states of the custom element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/states)
     */
    readonly states: CustomStateSet;
    /**
     * The **`validationMessage`** read-only property of the ElementInternals interface returns the validation message for the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the ElementInternals interface returns a ValidityState object which represents the different validity states the element can be in, with respect to constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`willValidate`** read-only property of the ElementInternals interface returns true if the element is a submittable element that is a candidate for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`checkValidity()`** method of the ElementInternals interface checks if the element meets any constraint validation rules applied to it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the ElementInternals interface checks if the element meets any constraint validation rules applied to it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`setFormValue()`** method of the ElementInternals interface sets the element's submission value and state, communicating these to the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/setFormValue)
     */
    setFormValue(value: File | string | FormData | null, state?: File | string | FormData | null): void;
    /**
     * The **`setValidity()`** method of the ElementInternals interface sets the validity of the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ElementInternals/setValidity)
     */
    setValidity(flags?: ValidityStateFlags, message?: string, anchor?: HTMLElement): void;
}

declare var ElementInternals: {
    prototype: ElementInternals;
    new(): ElementInternals;
};

/**
 * The **`EncodedAudioChunk`** interface of the WebCodecs API represents a chunk of encoded audio data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedAudioChunk)
 */
interface EncodedAudioChunk {
    /**
     * The **`byteLength`** read-only property of the EncodedAudioChunk interface returns the length in bytes of the encoded audio data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedAudioChunk/byteLength)
     */
    readonly byteLength: number;
    /**
     * The **`duration`** read-only property of the EncodedAudioChunk interface returns an integer indicating the duration of the audio in microseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedAudioChunk/duration)
     */
    readonly duration: number | null;
    /**
     * The **`timestamp`** read-only property of the EncodedAudioChunk interface returns an integer indicating the timestamp of the audio in microseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedAudioChunk/timestamp)
     */
    readonly timestamp: number;
    /**
     * The **`type`** read-only property of the EncodedAudioChunk interface returns a value indicating whether the audio chunk is a key chunk, which does not relying on other frames for decoding.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedAudioChunk/type)
     */
    readonly type: EncodedAudioChunkType;
    /**
     * The **`copyTo()`** method of the EncodedAudioChunk interface copies the encoded chunk of audio data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedAudioChunk/copyTo)
     */
    copyTo(destination: AllowSharedBufferSource): void;
}

declare var EncodedAudioChunk: {
    prototype: EncodedAudioChunk;
    new(init: EncodedAudioChunkInit): EncodedAudioChunk;
};

/**
 * The **`EncodedVideoChunk`** interface of the WebCodecs API represents a chunk of encoded video data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedVideoChunk)
 */
interface EncodedVideoChunk {
    /**
     * The **`byteLength`** read-only property of the EncodedVideoChunk interface returns the length in bytes of the encoded video data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedVideoChunk/byteLength)
     */
    readonly byteLength: number;
    /**
     * The **`duration`** read-only property of the EncodedVideoChunk interface returns an integer indicating the duration of the video in microseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedVideoChunk/duration)
     */
    readonly duration: number | null;
    /**
     * The **`timestamp`** read-only property of the EncodedVideoChunk interface returns an integer indicating the timestamp of the video in microseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedVideoChunk/timestamp)
     */
    readonly timestamp: number;
    /**
     * The **`type`** read-only property of the EncodedVideoChunk interface returns a value indicating whether the video chunk is a key chunk, which does not rely on other frames for decoding.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedVideoChunk/type)
     */
    readonly type: EncodedVideoChunkType;
    /**
     * The **`copyTo()`** method of the EncodedVideoChunk interface copies the encoded chunk of video data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EncodedVideoChunk/copyTo)
     */
    copyTo(destination: AllowSharedBufferSource): void;
}

declare var EncodedVideoChunk: {
    prototype: EncodedVideoChunk;
    new(init: EncodedVideoChunkInit): EncodedVideoChunk;
};

/**
 * The **`ErrorEvent`** interface represents events providing information related to errors in scripts or in files.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ErrorEvent)
 */
interface ErrorEvent extends Event {
    /**
     * The **`colno`** read-only property of the ErrorEvent interface returns an integer containing the column number of the script file on which the error occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ErrorEvent/colno)
     */
    readonly colno: number;
    /**
     * The **`error`** read-only property of the ErrorEvent interface returns a JavaScript value, such as an Error or DOMException, representing the error associated with this event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ErrorEvent/error)
     */
    readonly error: any;
    /**
     * The **`filename`** read-only property of the ErrorEvent interface returns a string containing the name of the script file in which the error occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ErrorEvent/filename)
     */
    readonly filename: string;
    /**
     * The **`lineno`** read-only property of the ErrorEvent interface returns an integer containing the line number of the script file on which the error occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ErrorEvent/lineno)
     */
    readonly lineno: number;
    /**
     * The **`message`** read-only property of the ErrorEvent interface returns a string containing a human-readable error message describing the problem.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ErrorEvent/message)
     */
    readonly message: string;
}

declare var ErrorEvent: {
    prototype: ErrorEvent;
    new(type: string, eventInitDict?: ErrorEventInit): ErrorEvent;
};

/**
 * The **`Event`** interface represents an event which takes place on an EventTarget.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event)
 */
interface Event {
    /**
     * The **`bubbles`** read-only property of the Event interface indicates whether the event bubbles up through the DOM tree or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/bubbles)
     */
    readonly bubbles: boolean;
    /**
     * The **`cancelBubble`** property of the Event interface is deprecated. Use Event.stopPropagation() instead. Setting its value to true before returning from an event handler prevents propagation of the event. In later implementations, setting this to false does nothing. See Browser compatibility for details.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/cancelBubble)
     */
    cancelBubble: boolean;
    /**
     * The **`cancelable`** read-only property of the Event interface indicates whether the event can be canceled, and therefore prevented as if the event never happened.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/cancelable)
     */
    readonly cancelable: boolean;
    /**
     * The read-only **`composed`** property of the Event interface returns a boolean value which indicates whether or not the event will propagate across the shadow DOM boundary into the standard DOM.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/composed)
     */
    readonly composed: boolean;
    /**
     * The **`currentTarget`** read-only property of the Event interface identifies the element to which the event handler has been attached.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/currentTarget)
     */
    readonly currentTarget: EventTarget | null;
    /**
     * The **`defaultPrevented`** read-only property of the Event interface returns a boolean value indicating whether or not the call to Event.preventDefault() canceled the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/defaultPrevented)
     */
    readonly defaultPrevented: boolean;
    /**
     * The **`eventPhase`** read-only property of the Event interface indicates which phase of the event flow is currently being evaluated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/eventPhase)
     */
    readonly eventPhase: number;
    /**
     * The **`isTrusted`** read-only property of the Event interface is a boolean value that is true when the event was generated by the user agent (including via user actions and programmatic methods such as HTMLElement.focus()), and false when the event was dispatched via EventTarget.dispatchEvent(). The only exception is the click event, which initializes the isTrusted property to false in user agents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/isTrusted)
     */
    readonly isTrusted: boolean;
    /**
     * The Event property **`returnValue`** indicates whether the default action for this event has been prevented or not.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/returnValue)
     */
    returnValue: boolean;
    /**
     * The deprecated **`Event.srcElement`** is an alias for the Event.target property. Use Event.target instead.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/srcElement)
     */
    readonly srcElement: EventTarget | null;
    /**
     * The read-only **`target`** property of the Event interface is a reference to the object onto which the event was dispatched. It is different from Event.currentTarget when the event handler is called during the bubbling or capturing phase of the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/target)
     */
    readonly target: EventTarget | null;
    /**
     * The **`timeStamp`** read-only property of the Event interface returns the time (in milliseconds) at which the event was created.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/timeStamp)
     */
    readonly timeStamp: DOMHighResTimeStamp;
    /**
     * The **`type`** read-only property of the Event interface returns a string containing the event's type. It is set when the event is constructed and is the name commonly used to refer to the specific event, such as click, load, or error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/type)
     */
    readonly type: string;
    /**
     * The **`composedPath()`** method of the Event interface returns the event's path which is an array of the objects on which listeners will be invoked. This does not include nodes in shadow trees if the shadow root was created with its ShadowRoot.mode closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/composedPath)
     */
    composedPath(): EventTarget[];
    /**
     * The **`Event.initEvent()`** method is used to initialize the value of an event created using Document.createEvent().
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/initEvent)
     */
    initEvent(type: string, bubbles?: boolean, cancelable?: boolean): void;
    /**
     * The **`preventDefault()`** method of the Event interface tells the user agent that the event is being explicitly handled, so its default action, such as page scrolling, link navigation, or pasting text, should not be taken.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/preventDefault)
     */
    preventDefault(): void;
    /**
     * The **`stopImmediatePropagation()`** method of the Event interface prevents other listeners of the same event from being called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/stopImmediatePropagation)
     */
    stopImmediatePropagation(): void;
    /**
     * The **`stopPropagation()`** method of the Event interface prevents further propagation of the current event in the capturing and bubbling phases. It does not, however, prevent any default behaviors from occurring; for instance, clicks on links are still processed. If you want to stop those behaviors, see the preventDefault() method. It also does not prevent propagation to other event-handlers of the current element. If you want to stop those, see stopImmediatePropagation().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Event/stopPropagation)
     */
    stopPropagation(): void;
    readonly NONE: 0;
    readonly CAPTURING_PHASE: 1;
    readonly AT_TARGET: 2;
    readonly BUBBLING_PHASE: 3;
}

declare var Event: {
    prototype: Event;
    new(type: string, eventInitDict?: EventInit): Event;
    readonly NONE: 0;
    readonly CAPTURING_PHASE: 1;
    readonly AT_TARGET: 2;
    readonly BUBBLING_PHASE: 3;
};

/**
 * The **`EventCounts`** interface of the Performance API provides the number of events that have been dispatched for each event type.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventCounts)
 */
interface EventCounts {
    forEach(callbackfn: (value: number, key: string, parent: EventCounts) => void, thisArg?: any): void;
}

declare var EventCounts: {
    prototype: EventCounts;
    new(): EventCounts;
};

interface EventListener {
    (evt: Event): void;
}

interface EventListenerObject {
    handleEvent(object: Event): void;
}

interface EventSourceEventMap {
    "error": Event;
    "message": MessageEvent;
    "open": Event;
}

/**
 * The **`EventSource`** interface is web content's interface to server-sent events.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource)
 */
interface EventSource extends EventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/error_event) */
    onerror: ((this: EventSource, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/message_event) */
    onmessage: ((this: EventSource, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/open_event) */
    onopen: ((this: EventSource, ev: Event) => any) | null;
    /**
     * The **`readyState`** read-only property of the EventSource interface returns a number representing the state of the connection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/readyState)
     */
    readonly readyState: number;
    /**
     * The **`url`** read-only property of the EventSource interface returns a string representing the URL of the source.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/url)
     */
    readonly url: string;
    /**
     * The **`withCredentials`** read-only property of the EventSource interface returns a boolean value indicating whether the EventSource object was instantiated with CORS credentials set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/withCredentials)
     */
    readonly withCredentials: boolean;
    /**
     * The **`close()`** method of the EventSource interface closes the connection, if one is made, and sets the EventSource.readyState attribute to 2 (closed).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventSource/close)
     */
    close(): void;
    readonly CONNECTING: 0;
    readonly OPEN: 1;
    readonly CLOSED: 2;
    addEventListener<K extends keyof EventSourceEventMap>(type: K, listener: (this: EventSource, ev: EventSourceEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: (this: EventSource, event: MessageEvent) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof EventSourceEventMap>(type: K, listener: (this: EventSource, ev: EventSourceEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: (this: EventSource, event: MessageEvent) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var EventSource: {
    prototype: EventSource;
    new(url: string | URL, eventSourceInitDict?: EventSourceInit): EventSource;
    readonly CONNECTING: 0;
    readonly OPEN: 1;
    readonly CLOSED: 2;
};

/**
 * The **`EventTarget`** interface is implemented by objects that can receive events and may have listeners for them. In other words, any target of events implements the three methods associated with this interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventTarget)
 */
interface EventTarget {
    /**
     * The **`addEventListener()`** method of the EventTarget interface sets up a function that will be called whenever the specified event is delivered to the target.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventTarget/addEventListener)
     */
    addEventListener(type: string, callback: EventListenerOrEventListenerObject | null, options?: AddEventListenerOptions | boolean): void;
    /**
     * The **`dispatchEvent()`** method of the EventTarget sends an Event to the object, (synchronously) invoking the affected event listeners in the appropriate order. The normal event processing rules (including the capturing and optional bubbling phase) also apply to events dispatched manually with dispatchEvent().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventTarget/dispatchEvent)
     */
    dispatchEvent(event: Event): boolean;
    /**
     * The **`removeEventListener()`** method of the EventTarget interface removes an event listener previously registered with EventTarget.addEventListener() from the target. The event listener to be removed is identified using a combination of the event type, the event listener function itself, and various optional options that may affect the matching process; see Matching event listeners for removal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/EventTarget/removeEventListener)
     */
    removeEventListener(type: string, callback: EventListenerOrEventListenerObject | null, options?: EventListenerOptions | boolean): void;
}

declare var EventTarget: {
    prototype: EventTarget;
    new(): EventTarget;
};

/** @deprecated */
interface External {
    /** @deprecated */
    AddSearchProvider(): void;
    /** @deprecated */
    IsSearchProviderInstalled(): void;
}

/** @deprecated */
declare var External: {
    prototype: External;
    new(): External;
};

/**
 * The **`File`** interface provides information about files and allows JavaScript in a web page to access their content.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/File)
 */
interface File extends Blob {
    /**
     * The **`lastModified`** read-only property of the File interface provides the last modified date of the file as the number of milliseconds since the Unix epoch (January 1, 1970 at midnight). Files without a known last modified date return the current date.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/File/lastModified)
     */
    readonly lastModified: number;
    /**
     * The **`name`** read-only property of the File interface returns the name of the file represented by a File object. For security reasons, the path is excluded from this property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/File/name)
     */
    readonly name: string;
    /**
     * The **`webkitRelativePath`** read-only property of the File interface contains a string which specifies the file's path relative to the directory selected by the user in an <input> element with its webkitdirectory attribute set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/File/webkitRelativePath)
     */
    readonly webkitRelativePath: string;
}

declare var File: {
    prototype: File;
    new(fileBits: BlobPart[], fileName: string, options?: FilePropertyBag): File;
};

/**
 * The **`FileList`** interface represents an object of this type returned by the files property of the HTML <input> element; this lets you access the list of files selected with the <input type="file"> element. It's also used for a list of files dropped into web content when using the drag and drop API; see the DataTransfer object for details on this usage.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileList)
 */
interface FileList {
    /**
     * The **`length`** read-only property of the FileList interface returns the number of files in the FileList.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileList/length)
     */
    readonly length: number;
    /**
     * The **`item()`** method of the FileList interface returns a File object representing the file at the specified index in the file list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileList/item)
     */
    item(index: number): File | null;
    [index: number]: File;
}

declare var FileList: {
    prototype: FileList;
    new(): FileList;
};

interface FileReaderEventMap {
    "abort": ProgressEvent<FileReader>;
    "error": ProgressEvent<FileReader>;
    "load": ProgressEvent<FileReader>;
    "loadend": ProgressEvent<FileReader>;
    "loadstart": ProgressEvent<FileReader>;
    "progress": ProgressEvent<FileReader>;
}

/**
 * The **`FileReader`** interface lets web applications asynchronously read the contents of files (or raw data buffers) stored on the user's computer, using File or Blob objects to specify the file or data to read.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader)
 */
interface FileReader extends EventTarget {
    /**
     * The **`error`** read-only property of the FileReader interface returns the error that occurred while reading the file.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/error)
     */
    readonly error: DOMException | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/abort_event) */
    onabort: ((this: FileReader, ev: ProgressEvent<FileReader>) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/error_event) */
    onerror: ((this: FileReader, ev: ProgressEvent<FileReader>) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/load_event) */
    onload: ((this: FileReader, ev: ProgressEvent<FileReader>) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/loadend_event) */
    onloadend: ((this: FileReader, ev: ProgressEvent<FileReader>) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/loadstart_event) */
    onloadstart: ((this: FileReader, ev: ProgressEvent<FileReader>) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/progress_event) */
    onprogress: ((this: FileReader, ev: ProgressEvent<FileReader>) => any) | null;
    /**
     * The **`readyState`** read-only property of the FileReader interface provides the current state of the reading operation. This will be one of the states: EMPTY, LOADING, or DONE.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/readyState)
     */
    readonly readyState: 0 | 1 | 2;
    /**
     * The **`result`** read-only property of the FileReader interface returns the file's contents. This property is only valid after the read operation is complete, and the format of the data depends on which of the methods was used to initiate the read operation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/result)
     */
    readonly result: string | ArrayBuffer | null;
    /**
     * The **`abort()`** method of the FileReader interface aborts the read operation. Upon return, the readyState will be DONE.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/abort)
     */
    abort(): void;
    /**
     * The **`readAsArrayBuffer()`** method of the FileReader interface is used to start reading the contents of a specified Blob or File. When the read operation is finished, the readyState property becomes DONE, and the loadend event is triggered. At that time, the result property contains an ArrayBuffer representing the file's data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/readAsArrayBuffer)
     */
    readAsArrayBuffer(blob: Blob): void;
    /**
     * The **`readAsBinaryString()`** method of the FileReader interface is used to start reading the contents of the specified Blob or File. When the read operation is finished, the readyState property becomes DONE, and the loadend event is triggered. At that time, the result property contains the raw binary data from the file.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/readAsBinaryString)
     */
    readAsBinaryString(blob: Blob): void;
    /**
     * The **`readAsDataURL()`** method of the FileReader interface is used to read the contents of the specified Blob or File. When the read operation is finished, the readyState property becomes DONE, and the loadend event is triggered. At that time, the result attribute contains the data as a data: URL representing the file's data as a base64 encoded string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/readAsDataURL)
     */
    readAsDataURL(blob: Blob): void;
    /**
     * The **`readAsText()`** method of the FileReader interface is used to read the contents of the specified Blob or File. When the read operation is complete, the readyState property is changed to DONE, the loadend event is triggered, and the result property contains the contents of the file as a text string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileReader/readAsText)
     */
    readAsText(blob: Blob, encoding?: string): void;
    readonly EMPTY: 0;
    readonly LOADING: 1;
    readonly DONE: 2;
    addEventListener<K extends keyof FileReaderEventMap>(type: K, listener: (this: FileReader, ev: FileReaderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof FileReaderEventMap>(type: K, listener: (this: FileReader, ev: FileReaderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var FileReader: {
    prototype: FileReader;
    new(): FileReader;
    readonly EMPTY: 0;
    readonly LOADING: 1;
    readonly DONE: 2;
};

/**
 * The File and Directory Entries API interface **`FileSystem`** is used to represent a file system. These objects can be obtained from the filesystem property on any file system entry. Some browsers offer additional APIs to create and manage file systems, such as Chrome's requestFileSystem() method.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystem)
 */
interface FileSystem {
    /**
     * The read-only **`name`** property of the FileSystem interface indicates the file system's name. This string is unique among all file systems currently exposed by the File and Directory Entries API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystem/name)
     */
    readonly name: string;
    /**
     * The read-only **`root`** property of the FileSystem interface specifies a FileSystemDirectoryEntry object representing the root directory of the file system, for use with the File and Directory Entries API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystem/root)
     */
    readonly root: FileSystemDirectoryEntry;
}

declare var FileSystem: {
    prototype: FileSystem;
    new(): FileSystem;
};

/**
 * The **`FileSystemDirectoryEntry`** interface of the File and Directory Entries API represents a directory in a file system. It provides methods which make it possible to access and manipulate the files in a directory, as well as to access the entries within the directory.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryEntry)
 */
interface FileSystemDirectoryEntry extends FileSystemEntry {
    /**
     * The FileSystemDirectoryEntry interface's method **`createReader()`** returns a FileSystemDirectoryReader object which can be used to read the entries in the directory.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryEntry/createReader)
     */
    createReader(): FileSystemDirectoryReader;
    /**
     * The FileSystemDirectoryEntry interface's method **`getDirectory()`** returns a FileSystemDirectoryEntry object corresponding to a directory contained somewhere within the directory subtree rooted at the directory on which it's called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryEntry/getDirectory)
     */
    getDirectory(path?: string | null, options?: FileSystemFlags, successCallback?: FileSystemEntryCallback, errorCallback?: ErrorCallback): void;
    /**
     * The FileSystemDirectoryEntry interface's method **`getFile()`** returns a FileSystemFileEntry object corresponding to a file contained somewhere within the directory subtree rooted at the directory on which it's called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryEntry/getFile)
     */
    getFile(path?: string | null, options?: FileSystemFlags, successCallback?: FileSystemEntryCallback, errorCallback?: ErrorCallback): void;
}

declare var FileSystemDirectoryEntry: {
    prototype: FileSystemDirectoryEntry;
    new(): FileSystemDirectoryEntry;
};

/**
 * The **`FileSystemDirectoryHandle`** interface of the File System API provides a handle to a file system directory.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryHandle)
 */
interface FileSystemDirectoryHandle extends FileSystemHandle {
    readonly kind: "directory";
    /**
     * The **`getDirectoryHandle()`** method of the FileSystemDirectoryHandle interface returns a FileSystemDirectoryHandle for a subdirectory with the specified name within the directory handle on which the method is called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryHandle/getDirectoryHandle)
     */
    getDirectoryHandle(name: string, options?: FileSystemGetDirectoryOptions): Promise<FileSystemDirectoryHandle>;
    /**
     * The **`getFileHandle()`** method of the FileSystemDirectoryHandle interface returns a FileSystemFileHandle for a file with the specified name, within the directory the method is called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryHandle/getFileHandle)
     */
    getFileHandle(name: string, options?: FileSystemGetFileOptions): Promise<FileSystemFileHandle>;
    /**
     * The **`removeEntry()`** method of the FileSystemDirectoryHandle interface attempts to remove an entry if the directory handle contains a file or directory called the name specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryHandle/removeEntry)
     */
    removeEntry(name: string, options?: FileSystemRemoveOptions): Promise<void>;
    /**
     * The **`resolve()`** method of the FileSystemDirectoryHandle interface returns an Array of directory names from the parent handle to the specified child entry, with the name of the child entry as the last array item.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryHandle/resolve)
     */
    resolve(possibleDescendant: FileSystemHandle): Promise<string[] | null>;
}

declare var FileSystemDirectoryHandle: {
    prototype: FileSystemDirectoryHandle;
    new(): FileSystemDirectoryHandle;
};

/**
 * The **`FileSystemDirectoryReader`** interface of the File and Directory Entries API lets you access the FileSystemFileEntry-based objects (generally FileSystemFileEntry or FileSystemDirectoryEntry) representing each entry in a directory.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryReader)
 */
interface FileSystemDirectoryReader {
    /**
     * The FileSystemDirectoryReader interface's **`readEntries()`** method retrieves the directory entries within the directory being read and delivers them in an array to a provided callback function.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemDirectoryReader/readEntries)
     */
    readEntries(successCallback: FileSystemEntriesCallback, errorCallback?: ErrorCallback): void;
}

declare var FileSystemDirectoryReader: {
    prototype: FileSystemDirectoryReader;
    new(): FileSystemDirectoryReader;
};

/**
 * The **`FileSystemEntry`** interface of the File and Directory Entries API represents a single entry in a file system. The entry can be a file or a directory (directories are represented by the FileSystemDirectoryEntry interface). It includes methods for working with files—including copying, moving, removing, and reading files—as well as information about a file it points to—including the file name and its path from the root to the entry.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry)
 */
interface FileSystemEntry {
    /**
     * The read-only **`filesystem`** property of the FileSystemEntry interface contains a FileSystem object that represents the file system on which the entry resides.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry/filesystem)
     */
    readonly filesystem: FileSystem;
    /**
     * The read-only **`fullPath`** property of the FileSystemEntry interface returns a string specifying the full, absolute path from the file system's root to the file represented by the entry.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry/fullPath)
     */
    readonly fullPath: string;
    /**
     * The read-only **`isDirectory`** property of the FileSystemEntry interface is true if the entry represents a directory (meaning it's a FileSystemDirectoryEntry) and false if it's not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry/isDirectory)
     */
    readonly isDirectory: boolean;
    /**
     * The read-only **`isFile`** property of the FileSystemEntry interface is true if the entry represents a file (meaning it's a FileSystemFileEntry) and false if it's not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry/isFile)
     */
    readonly isFile: boolean;
    /**
     * The read-only **`name`** property of the FileSystemEntry interface returns a string specifying the entry's name; this is the entry within its parent directory (the last component of the path as indicated by the fullPath property).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry/name)
     */
    readonly name: string;
    /**
     * The FileSystemEntry interface's method **`getParent()`** obtains a FileSystemDirectoryEntry.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemEntry/getParent)
     */
    getParent(successCallback?: FileSystemEntryCallback, errorCallback?: ErrorCallback): void;
}

declare var FileSystemEntry: {
    prototype: FileSystemEntry;
    new(): FileSystemEntry;
};

/**
 * The **`FileSystemFileEntry`** interface of the File and Directory Entries API represents a file in a file system. It offers properties describing the file's attributes, as well as the file() method, which creates a File object that can be used to read the file.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemFileEntry)
 */
interface FileSystemFileEntry extends FileSystemEntry {
    /**
     * The FileSystemFileEntry interface's method **`file()`** returns a File object which can be used to read data from the file represented by the directory entry.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemFileEntry/file)
     */
    file(successCallback: FileCallback, errorCallback?: ErrorCallback): void;
}

declare var FileSystemFileEntry: {
    prototype: FileSystemFileEntry;
    new(): FileSystemFileEntry;
};

/**
 * The **`FileSystemFileHandle`** interface of the File System API represents a handle to a file system entry. The interface is accessed through the window.showOpenFilePicker() method.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemFileHandle)
 */
interface FileSystemFileHandle extends FileSystemHandle {
    readonly kind: "file";
    /**
     * The **`createWritable()`** method of the FileSystemFileHandle interface creates a FileSystemWritableFileStream that can be used to write to a file. The method returns a Promise which resolves to this created stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemFileHandle/createWritable)
     */
    createWritable(options?: FileSystemCreateWritableOptions): Promise<FileSystemWritableFileStream>;
    /**
     * The **`getFile()`** method of the FileSystemFileHandle interface returns a Promise which resolves to a File object representing the state on disk of the entry represented by the handle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemFileHandle/getFile)
     */
    getFile(): Promise<File>;
}

declare var FileSystemFileHandle: {
    prototype: FileSystemFileHandle;
    new(): FileSystemFileHandle;
};

/**
 * The **`FileSystemHandle`** interface of the File System API is an object which represents a file or directory entry. Multiple handles can represent the same entry. For the most part you do not work with FileSystemHandle directly but rather its child interfaces FileSystemFileHandle and FileSystemDirectoryHandle.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemHandle)
 */
interface FileSystemHandle {
    /**
     * The **`kind`** read-only property of the FileSystemHandle interface returns the type of entry. This is 'file' if the associated entry is a file or 'directory'. It is used to distinguish files from directories when iterating over the contents of a directory.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemHandle/kind)
     */
    readonly kind: FileSystemHandleKind;
    /**
     * The **`name`** read-only property of the FileSystemHandle interface returns the name of the entry represented by handle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemHandle/name)
     */
    readonly name: string;
    /**
     * The **`isSameEntry()`** method of the FileSystemHandle interface compares two handles to see if the associated entries (either a file or directory) match.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemHandle/isSameEntry)
     */
    isSameEntry(other: FileSystemHandle): Promise<boolean>;
}

declare var FileSystemHandle: {
    prototype: FileSystemHandle;
    new(): FileSystemHandle;
};

/**
 * The **`FileSystemWritableFileStream`** interface of the File System API is a WritableStream object with additional convenience methods, which operates on a single file on disk. The interface is accessed through the FileSystemFileHandle.createWritable() method.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemWritableFileStream)
 */
interface FileSystemWritableFileStream extends WritableStream {
    /**
     * The **`seek()`** method of the FileSystemWritableFileStream interface updates the current file cursor offset to the position (in bytes) specified when calling the method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemWritableFileStream/seek)
     */
    seek(position: number): Promise<void>;
    /**
     * The **`truncate()`** method of the FileSystemWritableFileStream interface resizes the file associated with the stream to the specified size in bytes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemWritableFileStream/truncate)
     */
    truncate(size: number): Promise<void>;
    /**
     * The **`write()`** method of the FileSystemWritableFileStream interface writes content into the file the method is called on, at the current file cursor offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FileSystemWritableFileStream/write)
     */
    write(data: FileSystemWriteChunkType): Promise<void>;
}

declare var FileSystemWritableFileStream: {
    prototype: FileSystemWritableFileStream;
    new(): FileSystemWritableFileStream;
};

/**
 * The **`FocusEvent`** interface represents focus-related events, including focus, blur, focusin, and focusout.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FocusEvent)
 */
interface FocusEvent extends UIEvent {
    /**
     * The **`relatedTarget`** read-only property of the FocusEvent interface is the secondary target, depending on the type of event:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FocusEvent/relatedTarget)
     */
    readonly relatedTarget: EventTarget | null;
}

declare var FocusEvent: {
    prototype: FocusEvent;
    new(type: string, eventInitDict?: FocusEventInit): FocusEvent;
};

/**
 * The **`FontFace`** interface of the CSS Font Loading API represents a single usable font face.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace)
 */
interface FontFace {
    /**
     * The **`ascentOverride`** property of the FontFace interface returns and sets the ascent metric for the font, the height above the baseline that CSS uses to lay out line boxes in an inline formatting context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/ascentOverride)
     */
    ascentOverride: string;
    /**
     * The **`descentOverride`** property of the FontFace interface returns and sets the value of the descent-override descriptor. The possible values are normal, indicating that the metric used should be obtained from the font file, or a percentage.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/descentOverride)
     */
    descentOverride: string;
    /**
     * The **`display`** property of the FontFace interface determines how a font face is displayed based on whether and when it is downloaded and ready to use. This property is equivalent to the CSS font-display descriptor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/display)
     */
    display: FontDisplay;
    /**
     * The **`FontFace.family`** property allows the author to get or set the font family of a FontFace object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/family)
     */
    family: string;
    /**
     * The **`featureSettings`** property of the FontFace interface retrieves or sets infrequently used font features that are not available from a font's variant properties.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/featureSettings)
     */
    featureSettings: string;
    /**
     * The **`lineGapOverride`** property of the FontFace interface returns and sets the value of the line-gap-override descriptor. The possible values are normal, indicating that the metric used should be obtained from the font file, or a percentage.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/lineGapOverride)
     */
    lineGapOverride: string;
    /**
     * The **`loaded`** read-only property of the FontFace interface returns a Promise that resolves with the current FontFace object when the font specified in the object's constructor is done loading or rejects with a SyntaxError.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/loaded)
     */
    readonly loaded: Promise<FontFace>;
    /**
     * The **`status`** read-only property of the FontFace interface returns an enumerated value indicating the status of the font, one of "unloaded", "loading", "loaded", or "error".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/status)
     */
    readonly status: FontFaceLoadStatus;
    /**
     * The **`stretch`** property of the FontFace interface retrieves or sets how the font stretches.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/stretch)
     */
    stretch: string;
    /**
     * The **`style`** property of the FontFace interface retrieves or sets the font's style.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/style)
     */
    style: string;
    /**
     * The **`unicodeRange`** property of the FontFace interface retrieves or sets the range of unicode code points encompassing the font.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/unicodeRange)
     */
    unicodeRange: string;
    /**
     * The **`variationSettings`** property of the FontFace interface retrieves or sets low-level OpenType or TrueType font variations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/variationSettings)
     */
    variationSettings: string;
    /**
     * The **`weight`** property of the FontFace interface retrieves or sets the weight of the font.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/weight)
     */
    weight: string;
    /**
     * The **`load()`** method of the FontFace interface requests and loads a font whose source was specified as a URL. It returns a Promise that resolves with the current FontFace object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFace/load)
     */
    load(): Promise<FontFace>;
}

declare var FontFace: {
    prototype: FontFace;
    new(family: string, source: string | BufferSource, descriptors?: FontFaceDescriptors): FontFace;
};

interface FontFaceSetEventMap {
    "loading": FontFaceSetLoadEvent;
    "loadingdone": FontFaceSetLoadEvent;
    "loadingerror": FontFaceSetLoadEvent;
}

/**
 * The **`FontFaceSet`** interface of the CSS Font Loading API manages the loading of font-faces and querying of their download status.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet)
 */
interface FontFaceSet extends EventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/loading_event) */
    onloading: ((this: FontFaceSet, ev: FontFaceSetLoadEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/loadingdone_event) */
    onloadingdone: ((this: FontFaceSet, ev: FontFaceSetLoadEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/loadingerror_event) */
    onloadingerror: ((this: FontFaceSet, ev: FontFaceSetLoadEvent) => any) | null;
    /**
     * The **`ready`** read-only property of the FontFaceSet interface returns a Promise that resolves to the given FontFaceSet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/ready)
     */
    readonly ready: Promise<FontFaceSet>;
    /**
     * The **`status`** read-only property of the FontFaceSet interface returns the loading state of the fonts in the set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/status)
     */
    readonly status: FontFaceSetLoadStatus;
    /**
     * The **`check()`** method of the FontFaceSet returns true if you can render some text using the given font specification without attempting to use any fonts in this FontFaceSet that are not yet fully loaded. This means you can use the font specification without causing a font swap.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/check)
     */
    check(font: string, text?: string): boolean;
    /**
     * The **`load()`** method of the FontFaceSet forces all the fonts given in parameters to be loaded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSet/load)
     */
    load(font: string, text?: string): Promise<FontFace[]>;
    forEach(callbackfn: (value: FontFace, key: FontFace, parent: FontFaceSet) => void, thisArg?: any): void;
    addEventListener<K extends keyof FontFaceSetEventMap>(type: K, listener: (this: FontFaceSet, ev: FontFaceSetEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof FontFaceSetEventMap>(type: K, listener: (this: FontFaceSet, ev: FontFaceSetEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var FontFaceSet: {
    prototype: FontFaceSet;
    new(): FontFaceSet;
};

/**
 * The **`FontFaceSetLoadEvent`** interface of the CSS Font Loading API represents events fired at a FontFaceSet after it starts loading font faces.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSetLoadEvent)
 */
interface FontFaceSetLoadEvent extends Event {
    /**
     * The **`fontfaces`** read-only property of the FontFaceSetLoadEvent interface returns an array of FontFace instances, each of which represents a single usable font.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FontFaceSetLoadEvent/fontfaces)
     */
    readonly fontfaces: ReadonlyArray<FontFace>;
}

declare var FontFaceSetLoadEvent: {
    prototype: FontFaceSetLoadEvent;
    new(type: string, eventInitDict?: FontFaceSetLoadEventInit): FontFaceSetLoadEvent;
};

interface FontFaceSource {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/fonts) */
    readonly fonts: FontFaceSet;
}

/**
 * The **`FormData`** interface provides a way to construct a set of key/value pairs representing form fields and their values, which can be sent using the fetch(), XMLHttpRequest.send() or navigator.sendBeacon() methods. It uses the same format a form would use if the encoding type were set to "multipart/form-data".
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData)
 */
interface FormData {
    /**
     * The **`append()`** method of the FormData interface appends a new value onto an existing key inside a FormData object, or adds the key if it does not already exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData/append)
     */
    append(name: string, value: string | Blob): void;
    append(name: string, value: string): void;
    append(name: string, blobValue: Blob, filename?: string): void;
    /**
     * The **`delete()`** method of the FormData interface deletes a key and its value(s) from a FormData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData/delete)
     */
    delete(name: string): void;
    /**
     * The **`get()`** method of the FormData interface returns the first value associated with a given key from within a FormData object. If you expect multiple values and want all of them, use the getAll() method instead.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData/get)
     */
    get(name: string): FormDataEntryValue | null;
    /**
     * The **`getAll()`** method of the FormData interface returns all the values associated with a given key from within a FormData object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData/getAll)
     */
    getAll(name: string): FormDataEntryValue[];
    /**
     * The **`has()`** method of the FormData interface returns whether a FormData object contains a certain key.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData/has)
     */
    has(name: string): boolean;
    /**
     * The **`set()`** method of the FormData interface sets a new value for an existing key inside a FormData object, or adds the key/value if it does not already exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormData/set)
     */
    set(name: string, value: string | Blob): void;
    set(name: string, value: string): void;
    set(name: string, blobValue: Blob, filename?: string): void;
    forEach(callbackfn: (value: FormDataEntryValue, key: string, parent: FormData) => void, thisArg?: any): void;
}

declare var FormData: {
    prototype: FormData;
    new(form?: HTMLFormElement, submitter?: HTMLElement | null): FormData;
};

/**
 * The **`FormDataEvent`** interface represents a formdata event — such an event is fired on an HTMLFormElement object after the entry list representing the form's data is constructed. This happens when the form is submitted, but can also be triggered by the invocation of a FormData() constructor.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormDataEvent)
 */
interface FormDataEvent extends Event {
    /**
     * The **`formData`** read-only property of the FormDataEvent interface contains the FormData object representing the data contained in the form when the event was fired.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FormDataEvent/formData)
     */
    readonly formData: FormData;
}

declare var FormDataEvent: {
    prototype: FormDataEvent;
    new(type: string, eventInitDict: FormDataEventInit): FormDataEvent;
};

/**
 * The **`FragmentDirective`** interface is an object exposed to allow code to check whether or not a browser supports text fragments.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/FragmentDirective)
 */
interface FragmentDirective {
}

declare var FragmentDirective: {
    prototype: FragmentDirective;
    new(): FragmentDirective;
};

/**
 * The **`GPU`** interface of the WebGPU API is the starting point for using WebGPU. It can be used to return a GPUAdapter from which you can request devices, configure features and limits, and more.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPU)
 */
interface GPU {
    /**
     * The **`wgslLanguageFeatures`** read-only property of the GPU interface returns a WGSLLanguageFeatures object that reports the WGSL language extensions supported by the WebGPU implementation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPU/wgslLanguageFeatures)
     */
    readonly wgslLanguageFeatures: WGSLLanguageFeatures;
    /**
     * The **`getPreferredCanvasFormat()`** method of the GPU interface returns the optimal canvas texture format for displaying 8-bit depth, standard dynamic range content on the current system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPU/getPreferredCanvasFormat)
     */
    getPreferredCanvasFormat(): GPUTextureFormat;
    /**
     * The **`requestAdapter()`** method of the GPU interface returns a Promise that fulfills with a GPUAdapter object instance. From this you can request a GPUDevice, adapter info, features, and limits.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPU/requestAdapter)
     */
    requestAdapter(options?: GPURequestAdapterOptions): Promise<GPUAdapter | null>;
}

declare var GPU: {
    prototype: GPU;
    new(): GPU;
};

/**
 * The **`GPUAdapter`** interface of the WebGPU API represents a GPU adapter. From this you can request a GPUDevice, adapter info, features, and limits.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapter)
 */
interface GPUAdapter {
    /**
     * The **`features`** read-only property of the GPUAdapter interface returns a GPUSupportedFeatures object that describes additional functionality supported by the adapter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapter/features)
     */
    readonly features: GPUSupportedFeatures;
    /**
     * The **`info`** read-only property of the GPUAdapter interface returns a GPUAdapterInfo object containing identifying information about the adapter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapter/info)
     */
    readonly info: GPUAdapterInfo;
    /**
     * The **`limits`** read-only property of the GPUAdapter interface returns a GPUSupportedLimits object that describes the limits supported by the adapter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapter/limits)
     */
    readonly limits: GPUSupportedLimits;
    /**
     * The **`requestDevice()`** method of the GPUAdapter interface returns a Promise that fulfills with a GPUDevice object, which is the primary interface for communicating with the GPU.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapter/requestDevice)
     */
    requestDevice(descriptor?: GPUDeviceDescriptor): Promise<GPUDevice>;
}

declare var GPUAdapter: {
    prototype: GPUAdapter;
    new(): GPUAdapter;
};

/**
 * The **`GPUAdapterInfo`** interface of the WebGPU API contains identifying information about a GPUAdapter.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo)
 */
interface GPUAdapterInfo {
    /**
     * The **`architecture`** read-only property of the GPUAdapterInfo interface returns the name of the family or class of GPUs the adapter belongs to, or an empty string if it is not available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/architecture)
     */
    readonly architecture: string;
    /**
     * The **`description`** read-only property of the GPUAdapterInfo interface returns a human-readable string describing the adapter, or an empty string if it is not available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/description)
     */
    readonly description: string;
    /**
     * The **`device`** read-only property of the GPUAdapterInfo interface returns a vendor-specific identifier for the adapter, or an empty string if it is not available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/device)
     */
    readonly device: string;
    /**
     * The **`isFallbackAdapter`** read-only property of the GPUAdapterInfo interface returns true if the adapter is a fallback adapter, and false if not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/isFallbackAdapter)
     */
    readonly isFallbackAdapter: boolean;
    /**
     * The **`subgroupMaxSize`** read-only property of the GPUAdapterInfo interface returns the maximum supported subgroup size for the GPUAdapter. This can be used along with the subgroups feature.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/subgroupMaxSize)
     */
    readonly subgroupMaxSize: number;
    /**
     * The **`subgroupMinSize`** read-only property of the GPUAdapterInfo interface returns the minimum supported subgroup size for the GPUAdapter. This can be used along with the subgroups feature.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/subgroupMinSize)
     */
    readonly subgroupMinSize: number;
    /**
     * The **`vendor`** read-only property of the GPUAdapterInfo interface returns the name of the adapter vendor, or an empty string if it is not available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUAdapterInfo/vendor)
     */
    readonly vendor: string;
}

declare var GPUAdapterInfo: {
    prototype: GPUAdapterInfo;
    new(): GPUAdapterInfo;
};

/**
 * The **`GPUBindGroup`** interface of the WebGPU API is based on a GPUBindGroupLayout and defines a set of resources to be bound together in a group and how those resources are used in shader stages.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBindGroup)
 */
interface GPUBindGroup extends GPUObjectBase {
}

declare var GPUBindGroup: {
    prototype: GPUBindGroup;
    new(): GPUBindGroup;
};

/**
 * The **`GPUBindGroupLayout`** interface of the WebGPU API defines the structure and purpose of related GPU resources such as buffers that will be used in a pipeline, and is used as a template when creating GPUBindGroups.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBindGroupLayout)
 */
interface GPUBindGroupLayout extends GPUObjectBase {
}

declare var GPUBindGroupLayout: {
    prototype: GPUBindGroupLayout;
    new(): GPUBindGroupLayout;
};

interface GPUBindingCommandsMixin {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder/setBindGroup) */
    setBindGroup(index: GPUIndex32, bindGroup: GPUBindGroup | null, dynamicOffsets?: GPUBufferDynamicOffset[]): void;
    setBindGroup(index: GPUIndex32, bindGroup: GPUBindGroup | null, dynamicOffsetsData: Uint32Array<ArrayBufferLike>, dynamicOffsetsDataStart: GPUSize64, dynamicOffsetsDataLength: GPUSize32): void;
}

/**
 * The **`GPUBuffer`** interface of the WebGPU API represents a block of memory that can be used to store raw data to use in GPU operations.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer)
 */
interface GPUBuffer extends GPUObjectBase {
    /**
     * The **`mapState`** read-only property of the GPUBuffer interface represents the mapped state of the GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/mapState)
     */
    readonly mapState: GPUBufferMapState;
    /**
     * The **`size`** read-only property of the GPUBuffer interface represents the length of the GPUBuffer's memory allocation, in bytes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/size)
     */
    readonly size: GPUSize64Out;
    /**
     * The **`usage`** read-only property of the GPUBuffer interface contains the bitwise flags representing the allowed usages of the GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/usage)
     */
    readonly usage: GPUFlagsConstant;
    /**
     * The **`destroy()`** method of the GPUBuffer interface destroys the GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/destroy)
     */
    destroy(): void;
    /**
     * The **`getMappedRange()`** method of the GPUBuffer interface returns an ArrayBuffer containing the mapped contents of the GPUBuffer in the specified range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/getMappedRange)
     */
    getMappedRange(offset?: GPUSize64, size?: GPUSize64): ArrayBuffer;
    /**
     * The **`mapAsync()`** method of the GPUBuffer interface maps the specified range of the GPUBuffer. It returns a Promise that resolves when the GPUBuffer's content is ready to be accessed. While the GPUBuffer is mapped it cannot be used in any GPU commands.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/mapAsync)
     */
    mapAsync(mode: GPUMapModeFlags, offset?: GPUSize64, size?: GPUSize64): Promise<void>;
    /**
     * The **`unmap()`** method of the GPUBuffer interface unmaps the mapped range of the GPUBuffer, making its contents available for use by the GPU again after it has previously been mapped with GPUBuffer.mapAsync() (the GPU cannot access a mapped GPUBuffer).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBuffer/unmap)
     */
    unmap(): void;
}

declare var GPUBuffer: {
    prototype: GPUBuffer;
    new(): GPUBuffer;
};

/**
 * The **`GPUCanvasContext`** interface of the WebGPU API represents the WebGPU rendering context of a <canvas> element, returned via an HTMLCanvasElement.getContext() call with a contextType of "webgpu".
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCanvasContext)
 */
interface GPUCanvasContext {
    /**
     * The **`canvas`** read-only property of the GPUCanvasContext interface returns a reference to the canvas that the context was created from.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCanvasContext/canvas)
     */
    readonly canvas: HTMLCanvasElement | OffscreenCanvas;
    /**
     * The **`configure()`** method of the GPUCanvasContext interface configures the context to use for rendering with a given GPUDevice. When called the canvas will initially be cleared to transparent black.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCanvasContext/configure)
     */
    configure(configuration: GPUCanvasConfiguration): void;
    /**
     * The **`getConfiguration()`** method of the GPUCanvasContext interface returns the current configuration set for the context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCanvasContext/getConfiguration)
     */
    getConfiguration(): GPUCanvasConfiguration | null;
    /**
     * The **`getCurrentTexture()`** method of the GPUCanvasContext interface returns the next GPUTexture to be composited to the document by the canvas context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCanvasContext/getCurrentTexture)
     */
    getCurrentTexture(): GPUTexture;
    /**
     * The **`unconfigure()`** method of the GPUCanvasContext interface removes any previously-set context configuration, and destroys any textures returned via getCurrentTexture() while the canvas context was configured.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCanvasContext/unconfigure)
     */
    unconfigure(): void;
}

declare var GPUCanvasContext: {
    prototype: GPUCanvasContext;
    new(): GPUCanvasContext;
};

/**
 * The **`GPUCommandBuffer`** interface of the WebGPU API represents a pre-recorded list of GPU commands that can be submitted to a GPUQueue for execution.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandBuffer)
 */
interface GPUCommandBuffer extends GPUObjectBase {
}

declare var GPUCommandBuffer: {
    prototype: GPUCommandBuffer;
    new(): GPUCommandBuffer;
};

/**
 * The **`GPUCommandEncoder`** interface of the WebGPU API represents an encoder that collects a sequence of GPU commands to be issued to the GPU.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder)
 */
interface GPUCommandEncoder extends GPUDebugCommandsMixin, GPUObjectBase {
    /**
     * The **`beginComputePass()`** method of the GPUCommandEncoder interface starts encoding a compute pass, returning a GPUComputePassEncoder that can be used to control computation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/beginComputePass)
     */
    beginComputePass(descriptor?: GPUComputePassDescriptor): GPUComputePassEncoder;
    /**
     * The **`beginRenderPass()`** method of the GPUCommandEncoder interface starts encoding a render pass, returning a GPURenderPassEncoder that can be used to control rendering.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/beginRenderPass)
     */
    beginRenderPass(descriptor: GPURenderPassDescriptor): GPURenderPassEncoder;
    /**
     * The **`clearBuffer()`** method of the GPUCommandEncoder interface encodes a command that fills a region of a GPUBuffer with zeroes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/clearBuffer)
     */
    clearBuffer(buffer: GPUBuffer, offset?: GPUSize64, size?: GPUSize64): void;
    /**
     * The **`copyBufferToBuffer()`** method of the GPUCommandEncoder interface encodes a command that copies data from one GPUBuffer to another.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyBufferToBuffer)
     */
    copyBufferToBuffer(source: GPUBuffer, destination: GPUBuffer, size?: GPUSize64): void;
    copyBufferToBuffer(source: GPUBuffer, sourceOffset: GPUSize64, destination: GPUBuffer, destinationOffset: GPUSize64, size?: GPUSize64): void;
    /**
     * The **`copyBufferToTexture()`** method of the GPUCommandEncoder interface encodes a command that copies data from a GPUBuffer to a GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyBufferToTexture)
     */
    copyBufferToTexture(source: GPUTexelCopyBufferInfo, destination: GPUTexelCopyTextureInfo, copySize: GPUExtent3D): void;
    /**
     * The **`copyTextureToBuffer()`** method of the GPUCommandEncoder interface encodes a command that copies data from a GPUTexture to a GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyTextureToBuffer)
     */
    copyTextureToBuffer(source: GPUTexelCopyTextureInfo, destination: GPUTexelCopyBufferInfo, copySize: GPUExtent3D): void;
    /**
     * The **`copyTextureToTexture()`** method of the GPUCommandEncoder interface encodes a command that copies data from one GPUTexture to another.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/copyTextureToTexture)
     */
    copyTextureToTexture(source: GPUTexelCopyTextureInfo, destination: GPUTexelCopyTextureInfo, copySize: GPUExtent3D): void;
    /**
     * The **`finish()`** method of the GPUCommandEncoder interface completes recording of the command sequence encoded on this GPUCommandEncoder, returning a corresponding GPUCommandBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/finish)
     */
    finish(descriptor?: GPUCommandBufferDescriptor): GPUCommandBuffer;
    /**
     * The **`resolveQuerySet()`** method of the GPUCommandEncoder interface encodes a command that resolves a GPUQuerySet, copying the results into a specified GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/resolveQuerySet)
     */
    resolveQuerySet(querySet: GPUQuerySet, firstQuery: GPUSize32, queryCount: GPUSize32, destination: GPUBuffer, destinationOffset: GPUSize64): void;
}

declare var GPUCommandEncoder: {
    prototype: GPUCommandEncoder;
    new(): GPUCommandEncoder;
};

/**
 * The **`GPUCompilationInfo`** interface of the WebGPU API represents an array of GPUCompilationMessage objects generated by the GPU shader module compiler to help diagnose problems with shader code.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationInfo)
 */
interface GPUCompilationInfo {
    /**
     * The **`messages`** read-only property of the GPUCompilationInfo interface is an array of GPUCompilationMessage objects, each one containing the details of an individual shader compilation message. Messages can be informational, warnings, or errors.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationInfo/messages)
     */
    readonly messages: ReadonlyArray<GPUCompilationMessage>;
}

declare var GPUCompilationInfo: {
    prototype: GPUCompilationInfo;
    new(): GPUCompilationInfo;
};

/**
 * The **`GPUCompilationMessage`** interface of the WebGPU API represents a single informational, warning, or error message generated by the GPU shader module compiler.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage)
 */
interface GPUCompilationMessage {
    /**
     * The **`length`** read-only property of the GPUCompilationMessage interface is a number representing the length of the substring that the message corresponds to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage/length)
     */
    readonly length: number;
    /**
     * The **`lineNum`** read-only property of the GPUCompilationMessage interface is a number representing the line number in the shader code that the message corresponds to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage/lineNum)
     */
    readonly lineNum: number;
    /**
     * The **`linePos`** read-only property of the GPUCompilationMessage interface is a number representing the position in the code line that the message corresponds to. This could be an exact point, or the start of the relevant substring.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage/linePos)
     */
    readonly linePos: number;
    /**
     * The **`message`** read-only property of the GPUCompilationMessage interface is a string representing human-readable message text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage/message)
     */
    readonly message: string;
    /**
     * The **`offset`** read-only property of the GPUCompilationMessage interface is a number representing the offset from the start of the shader code to the exact point, or the start of the relevant substring, that the message corresponds to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage/offset)
     */
    readonly offset: number;
    /**
     * The **`type`** read-only property of the GPUCompilationMessage interface is an enumerated value representing the type of the message. Each type represents a different severity level.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCompilationMessage/type)
     */
    readonly type: GPUCompilationMessageType;
}

declare var GPUCompilationMessage: {
    prototype: GPUCompilationMessage;
    new(): GPUCompilationMessage;
};

/**
 * The **`GPUComputePassEncoder`** interface of the WebGPU API encodes commands related to controlling the compute shader stage, as issued by a GPUComputePipeline. It forms part of the overall encoding activity of a GPUCommandEncoder.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder)
 */
interface GPUComputePassEncoder extends GPUBindingCommandsMixin, GPUDebugCommandsMixin, GPUObjectBase {
    /**
     * The **`dispatchWorkgroups()`** method of the GPUComputePassEncoder interface dispatches a specific grid of workgroups to perform the work being done by the current GPUComputePipeline (i.e., set via GPUComputePassEncoder.setPipeline()).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder/dispatchWorkgroups)
     */
    dispatchWorkgroups(workgroupCountX: GPUSize32, workgroupCountY?: GPUSize32, workgroupCountZ?: GPUSize32): void;
    /**
     * The **`dispatchWorkgroupsIndirect()`** method of the GPUComputePassEncoder interface dispatches a grid of workgroups, defined by the parameters of a GPUBuffer, to perform the work being done by the current GPUComputePipeline (i.e., set via GPUComputePassEncoder.setPipeline()).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder/dispatchWorkgroupsIndirect)
     */
    dispatchWorkgroupsIndirect(indirectBuffer: GPUBuffer, indirectOffset: GPUSize64): void;
    /**
     * The **`end()`** method of the GPUComputePassEncoder interface completes recording of the current compute pass command sequence.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder/end)
     */
    end(): void;
    /**
     * The **`setPipeline()`** method of the GPUComputePassEncoder interface sets the GPUComputePipeline to use for this compute pass.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePassEncoder/setPipeline)
     */
    setPipeline(pipeline: GPUComputePipeline): void;
}

declare var GPUComputePassEncoder: {
    prototype: GPUComputePassEncoder;
    new(): GPUComputePassEncoder;
};

/**
 * The **`GPUComputePipeline`** interface of the WebGPU API represents a pipeline that controls the compute shader stage and can be used in a GPUComputePassEncoder.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePipeline)
 */
interface GPUComputePipeline extends GPUObjectBase, GPUPipelineBase {
}

declare var GPUComputePipeline: {
    prototype: GPUComputePipeline;
    new(): GPUComputePipeline;
};

interface GPUDebugCommandsMixin {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/insertDebugMarker) */
    insertDebugMarker(markerLabel: string): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/popDebugGroup) */
    popDebugGroup(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUCommandEncoder/pushDebugGroup) */
    pushDebugGroup(groupLabel: string): void;
}

interface GPUDeviceEventMap {
    "uncapturederror": GPUUncapturedErrorEvent;
}

/**
 * The **`GPUDevice`** interface of the WebGPU API represents a logical GPU device. This is the main interface through which the majority of WebGPU functionality is accessed.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice)
 */
interface GPUDevice extends EventTarget, GPUObjectBase {
    /**
     * The **`adapterInfo`** read-only property of the GPUDevice interface returns a GPUAdapterInfo object containing identifying information about the device's originating adapter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/adapterInfo)
     */
    readonly adapterInfo: GPUAdapterInfo;
    /**
     * The **`features`** read-only property of the GPUDevice interface returns a GPUSupportedFeatures object that describes additional functionality supported by the device. Only features requested during the creation of the device (i.e., when GPUAdapter.requestDevice() is called) are included.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/features)
     */
    readonly features: GPUSupportedFeatures;
    /**
     * The **`limits`** read-only property of the GPUDevice interface returns a GPUSupportedLimits object that describes the limits supported by the device. All limit values will be included, and the limits requested during the creation of the device (i.e., when GPUAdapter.requestDevice() is called) will be reflected in those values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/limits)
     */
    readonly limits: GPUSupportedLimits;
    /**
     * The **`lost`** read-only property of the GPUDevice interface contains a Promise that remains pending throughout the device's lifetime and resolves with a GPUDeviceLostInfo object when the device is lost.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/lost)
     */
    readonly lost: Promise<GPUDeviceLostInfo>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/uncapturederror_event) */
    onuncapturederror: ((this: GPUDevice, ev: GPUUncapturedErrorEvent) => any) | null;
    /**
     * The **`queue`** read-only property of the GPUDevice interface returns the primary GPUQueue for the device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/queue)
     */
    readonly queue: GPUQueue;
    /**
     * The **`createBindGroup()`** method of the GPUDevice interface creates a GPUBindGroup based on a GPUBindGroupLayout that defines a set of resources to be bound together in a group and how those resources are used in shader stages.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createBindGroup)
     */
    createBindGroup(descriptor: GPUBindGroupDescriptor): GPUBindGroup;
    /**
     * The **`createBindGroupLayout()`** method of the GPUDevice interface creates a GPUBindGroupLayout that defines the structure and purpose of related GPU resources such as buffers that will be used in a pipeline, and is used as a template when creating GPUBindGroups.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createBindGroupLayout)
     */
    createBindGroupLayout(descriptor: GPUBindGroupLayoutDescriptor): GPUBindGroupLayout;
    /**
     * The **`createBuffer()`** method of the GPUDevice interface creates a GPUBuffer in which to store raw data to use in GPU operations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createBuffer)
     */
    createBuffer(descriptor: GPUBufferDescriptor): GPUBuffer;
    /**
     * The **`createCommandEncoder()`** method of the GPUDevice interface creates a GPUCommandEncoder, used to encode commands to be issued to the GPU.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createCommandEncoder)
     */
    createCommandEncoder(descriptor?: GPUCommandEncoderDescriptor): GPUCommandEncoder;
    /**
     * The **`createComputePipeline()`** method of the GPUDevice interface creates a GPUComputePipeline that can control the compute shader stage and be used in a GPUComputePassEncoder.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createComputePipeline)
     */
    createComputePipeline(descriptor: GPUComputePipelineDescriptor): GPUComputePipeline;
    /**
     * The **`createComputePipelineAsync()`** method of the GPUDevice interface returns a Promise that fulfills with a GPUComputePipeline, which can control the compute shader stage and be used in a GPUComputePassEncoder, once the pipeline can be used without any stalling.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createComputePipelineAsync)
     */
    createComputePipelineAsync(descriptor: GPUComputePipelineDescriptor): Promise<GPUComputePipeline>;
    /**
     * The **`createPipelineLayout()`** method of the GPUDevice interface creates a GPUPipelineLayout that defines the GPUBindGroupLayouts used by a pipeline. GPUBindGroups used with the pipeline during command encoding must have compatible GPUBindGroupLayouts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createPipelineLayout)
     */
    createPipelineLayout(descriptor: GPUPipelineLayoutDescriptor): GPUPipelineLayout;
    /**
     * The **`createQuerySet()`** method of the GPUDevice interface creates a GPUQuerySet that can be used to record the results of queries on passes, such as occlusion or timestamp queries.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createQuerySet)
     */
    createQuerySet(descriptor: GPUQuerySetDescriptor): GPUQuerySet;
    /**
     * The **`createRenderBundleEncoder()`** method of the GPUDevice interface creates a GPURenderBundleEncoder that can be used to pre-record bundles of commands. These can be reused in GPURenderPassEncoders via the executeBundles() method, as many times as required.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createRenderBundleEncoder)
     */
    createRenderBundleEncoder(descriptor: GPURenderBundleEncoderDescriptor): GPURenderBundleEncoder;
    /**
     * The **`createRenderPipeline()`** method of the GPUDevice interface creates a GPURenderPipeline that can control the vertex and fragment shader stages and be used in a GPURenderPassEncoder or GPURenderBundleEncoder.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createRenderPipeline)
     */
    createRenderPipeline(descriptor: GPURenderPipelineDescriptor): GPURenderPipeline;
    /**
     * The **`createRenderPipelineAsync()`** method of the GPUDevice interface returns a Promise that fulfills with a GPURenderPipeline, which can control the vertex and fragment shader stages and be used in a GPURenderPassEncoder or GPURenderBundleEncoder, once the pipeline can be used without any stalling.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createRenderPipelineAsync)
     */
    createRenderPipelineAsync(descriptor: GPURenderPipelineDescriptor): Promise<GPURenderPipeline>;
    /**
     * The **`createSampler()`** method of the GPUDevice interface creates a GPUSampler, which controls how shaders transform and filter texture resource data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createSampler)
     */
    createSampler(descriptor?: GPUSamplerDescriptor): GPUSampler;
    /**
     * The **`createShaderModule()`** method of the GPUDevice interface creates a GPUShaderModule from a string of WGSL source code.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createShaderModule)
     */
    createShaderModule(descriptor: GPUShaderModuleDescriptor): GPUShaderModule;
    /**
     * The **`createTexture()`** method of the GPUDevice interface creates a GPUTexture in which to store 1D, 2D, or 3D arrays of data, such as images, to use in GPU rendering operations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/createTexture)
     */
    createTexture(descriptor: GPUTextureDescriptor): GPUTexture;
    /**
     * The **`destroy()`** method of the GPUDevice interface destroys the device, preventing further operations on it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/destroy)
     */
    destroy(): void;
    /**
     * The **`importExternalTexture()`** method of the GPUDevice interface takes an HTMLVideoElement or a VideoFrame object as an input and returns a GPUExternalTexture wrapper object containing a snapshot of the video that can be used as a frame in GPU rendering operations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/importExternalTexture)
     */
    importExternalTexture(descriptor: GPUExternalTextureDescriptor): GPUExternalTexture;
    /**
     * The **`popErrorScope()`** method of the GPUDevice interface pops an existing GPU error scope from the error scope stack (originally pushed using GPUDevice.pushErrorScope()) and returns a Promise that resolves to an object describing the first error captured in the scope, or null if no error occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/popErrorScope)
     */
    popErrorScope(): Promise<GPUError | null>;
    /**
     * The **`pushErrorScope()`** method of the GPUDevice interface pushes a new GPU error scope onto the device's error scope stack, allowing you to capture errors of a particular type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDevice/pushErrorScope)
     */
    pushErrorScope(filter: GPUErrorFilter): void;
    addEventListener<K extends keyof GPUDeviceEventMap>(type: K, listener: (this: GPUDevice, ev: GPUDeviceEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof GPUDeviceEventMap>(type: K, listener: (this: GPUDevice, ev: GPUDeviceEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var GPUDevice: {
    prototype: GPUDevice;
    new(): GPUDevice;
};

/**
 * The **`GPUDeviceLostInfo`** interface of the WebGPU API represents the object returned when the GPUDevice.lost Promise resolves. This provides information as to why a device has been lost.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDeviceLostInfo)
 */
interface GPUDeviceLostInfo {
    /**
     * The **`message`** read-only property of the GPUDeviceLostInfo interface provides a human-readable message that explains why the device was lost.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDeviceLostInfo/message)
     */
    readonly message: string;
    /**
     * The **`reason`** read-only property of the GPUDeviceLostInfo interface defines the reason the device was lost in a machine-readable way.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUDeviceLostInfo/reason)
     */
    readonly reason: GPUDeviceLostReason;
}

declare var GPUDeviceLostInfo: {
    prototype: GPUDeviceLostInfo;
    new(): GPUDeviceLostInfo;
};

/**
 * The **`GPUError`** interface of the WebGPU API is the base interface for errors surfaced by GPUDevice.popErrorScope and the uncapturederror event.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUError)
 */
interface GPUError {
    /**
     * The **`message`** read-only property of the GPUError interface provides a human-readable message that explains why the error occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUError/message)
     */
    readonly message: string;
}

declare var GPUError: {
    prototype: GPUError;
    new(): GPUError;
};

/**
 * The **`GPUExternalTexture`** interface of the WebGPU API represents a wrapper object containing an HTMLVideoElement snapshot that can be used as a texture in GPU rendering operations.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUExternalTexture)
 */
interface GPUExternalTexture extends GPUObjectBase {
}

declare var GPUExternalTexture: {
    prototype: GPUExternalTexture;
    new(): GPUExternalTexture;
};

/**
 * The **`GPUInternalError`** interface of the WebGPU API describes an application error indicating that an operation failed for a system or implementation-specific reason, even when all validation requirements were satisfied.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUInternalError)
 */
interface GPUInternalError extends GPUError {
}

declare var GPUInternalError: {
    prototype: GPUInternalError;
    new(message: string): GPUInternalError;
};

interface GPUObjectBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUBindGroup/label) */
    label: string;
}

/**
 * The **`GPUOutOfMemoryError`** interface of the WebGPU API describes an out-of-memory (oom) error indicating that there was not enough free memory to complete the requested operation.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUOutOfMemoryError)
 */
interface GPUOutOfMemoryError extends GPUError {
}

declare var GPUOutOfMemoryError: {
    prototype: GPUOutOfMemoryError;
    new(message: string): GPUOutOfMemoryError;
};

interface GPUPipelineBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUComputePipeline/getBindGroupLayout) */
    getBindGroupLayout(index: number): GPUBindGroupLayout;
}

/**
 * The **`GPUPipelineError`** interface of the WebGPU API describes a pipeline failure. This is the value received when a Promise returned by a GPUDevice.createComputePipelineAsync() or GPUDevice.createRenderPipelineAsync() call rejects.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUPipelineError)
 */
interface GPUPipelineError extends DOMException {
    /**
     * The **`reason`** read-only property of the GPUPipelineError interface defines the reason the pipeline creation failed in a machine-readable way.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUPipelineError/reason)
     */
    readonly reason: GPUPipelineErrorReason;
}

declare var GPUPipelineError: {
    prototype: GPUPipelineError;
    new(message: string, options: GPUPipelineErrorInit): GPUPipelineError;
};

/**
 * The **`GPUPipelineLayout`** interface of the WebGPU API defines the GPUBindGroupLayouts used by a pipeline. GPUBindGroups used with the pipeline during command encoding must have compatible GPUBindGroupLayouts.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUPipelineLayout)
 */
interface GPUPipelineLayout extends GPUObjectBase {
}

declare var GPUPipelineLayout: {
    prototype: GPUPipelineLayout;
    new(): GPUPipelineLayout;
};

/**
 * The **`GPUQuerySet`** interface of the WebGPU API is used to record the results of queries on passes, such as occlusion or timestamp queries.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQuerySet)
 */
interface GPUQuerySet extends GPUObjectBase {
    /**
     * The **`count`** read-only property of the GPUQuerySet interface is a number specifying the number of queries managed by the GPUQuerySet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQuerySet/count)
     */
    readonly count: GPUSize32Out;
    /**
     * The **`type`** read-only property of the GPUQuerySet interface is an enumerated value specifying the type of queries managed by the GPUQuerySet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQuerySet/type)
     */
    readonly type: GPUQueryType;
    /**
     * The **`destroy()`** method of the GPUQuerySet interface destroys the GPUQuerySet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQuerySet/destroy)
     */
    destroy(): void;
}

declare var GPUQuerySet: {
    prototype: GPUQuerySet;
    new(): GPUQuerySet;
};

/**
 * The **`GPUQueue`** interface of the WebGPU API controls execution of encoded commands on the GPU.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue)
 */
interface GPUQueue extends GPUObjectBase {
    /**
     * The **`copyExternalImageToTexture()`** method of the GPUQueue interface copies a snapshot taken from a source image, video, or canvas into a given GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/copyExternalImageToTexture)
     */
    copyExternalImageToTexture(source: GPUCopyExternalImageSourceInfo, destination: GPUCopyExternalImageDestInfo, copySize: GPUExtent3D): void;
    /**
     * The **`onSubmittedWorkDone()`** method of the GPUQueue interface returns a Promise that resolves when all the work submitted to the GPU via this GPUQueue at the point the method is called has been processed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/onSubmittedWorkDone)
     */
    onSubmittedWorkDone(): Promise<void>;
    /**
     * The **`submit()`** method of the GPUQueue interface schedules the execution of command buffers represented by one or more GPUCommandBuffer objects by the GPU.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/submit)
     */
    submit(commandBuffers: GPUCommandBuffer[]): void;
    /**
     * The **`writeBuffer()`** method of the GPUQueue interface writes a provided data source into a given GPUBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/writeBuffer)
     */
    writeBuffer(buffer: GPUBuffer, bufferOffset: GPUSize64, data: AllowSharedBufferSource, dataOffset?: GPUSize64, size?: GPUSize64): void;
    /**
     * The **`writeTexture()`** method of the GPUQueue interface writes a provided data source into a given GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUQueue/writeTexture)
     */
    writeTexture(destination: GPUTexelCopyTextureInfo, data: AllowSharedBufferSource, dataLayout: GPUTexelCopyBufferLayout, size: GPUExtent3D): void;
}

declare var GPUQueue: {
    prototype: GPUQueue;
    new(): GPUQueue;
};

/**
 * The **`GPURenderBundle`** interface of the WebGPU API represents a container for pre-recorded bundles of commands.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundle)
 */
interface GPURenderBundle extends GPUObjectBase {
}

declare var GPURenderBundle: {
    prototype: GPURenderBundle;
    new(): GPURenderBundle;
};

/**
 * The **`GPURenderBundleEncoder`** interface of the WebGPU API is used to pre-record bundles of commands.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder)
 */
interface GPURenderBundleEncoder extends GPUBindingCommandsMixin, GPUDebugCommandsMixin, GPUObjectBase, GPURenderCommandsMixin {
    /**
     * The **`finish()`** method of the GPURenderBundleEncoder interface completes recording of the current render bundle command sequence, returning a GPURenderBundle object that can be passed into a GPURenderPassEncoder.executeBundles() call to execute those commands in a specific render pass.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/finish)
     */
    finish(descriptor?: GPURenderBundleDescriptor): GPURenderBundle;
}

declare var GPURenderBundleEncoder: {
    prototype: GPURenderBundleEncoder;
    new(): GPURenderBundleEncoder;
};

interface GPURenderCommandsMixin {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/draw) */
    draw(vertexCount: GPUSize32, instanceCount?: GPUSize32, firstVertex?: GPUSize32, firstInstance?: GPUSize32): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/drawIndexed) */
    drawIndexed(indexCount: GPUSize32, instanceCount?: GPUSize32, firstIndex?: GPUSize32, baseVertex?: GPUSignedOffset32, firstInstance?: GPUSize32): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/drawIndexedIndirect) */
    drawIndexedIndirect(indirectBuffer: GPUBuffer, indirectOffset: GPUSize64): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/drawIndirect) */
    drawIndirect(indirectBuffer: GPUBuffer, indirectOffset: GPUSize64): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/setIndexBuffer) */
    setIndexBuffer(buffer: GPUBuffer, indexFormat: GPUIndexFormat, offset?: GPUSize64, size?: GPUSize64): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/setPipeline) */
    setPipeline(pipeline: GPURenderPipeline): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderBundleEncoder/setVertexBuffer) */
    setVertexBuffer(slot: GPUIndex32, buffer: GPUBuffer | null, offset?: GPUSize64, size?: GPUSize64): void;
}

/**
 * The **`GPURenderPassEncoder`** interface of the WebGPU API encodes commands related to controlling the vertex and fragment shader stages, as issued by a GPURenderPipeline. It forms part of the overall encoding activity of a GPUCommandEncoder.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder)
 */
interface GPURenderPassEncoder extends GPUBindingCommandsMixin, GPUDebugCommandsMixin, GPUObjectBase, GPURenderCommandsMixin {
    /**
     * The **`beginOcclusionQuery()`** method of the GPURenderPassEncoder interface begins an occlusion query at the specified index of the relevant GPUQuerySet (provided as the value of the occlusionQuerySet descriptor property when invoking GPUCommandEncoder.beginRenderPass() to run the render pass).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/beginOcclusionQuery)
     */
    beginOcclusionQuery(queryIndex: GPUSize32): void;
    /**
     * The **`end()`** method of the GPURenderPassEncoder interface completes recording of the current render pass command sequence.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/end)
     */
    end(): void;
    /**
     * The **`endOcclusionQuery()`** method of the GPURenderPassEncoder interface ends an active occlusion query previously started with beginOcclusionQuery().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/endOcclusionQuery)
     */
    endOcclusionQuery(): void;
    /**
     * The **`executeBundles()`** method of the GPURenderPassEncoder interface executes commands previously recorded into the referenced GPURenderBundles, as part of this render pass.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/executeBundles)
     */
    executeBundles(bundles: GPURenderBundle[]): void;
    /**
     * The **`setBlendConstant()`** method of the GPURenderPassEncoder interface sets the constant blend color and alpha values used with "constant" and "one-minus-constant" blend factors (as set in the descriptor of the GPUDevice.createRenderPipeline() method, in the blend property).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/setBlendConstant)
     */
    setBlendConstant(color: GPUColor): void;
    /**
     * The **`setScissorRect()`** method of the GPURenderPassEncoder interface sets the scissor rectangle used during the rasterization stage. After transformation into viewport coordinates any fragments that fall outside the scissor rectangle will be discarded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/setScissorRect)
     */
    setScissorRect(x: GPUIntegerCoordinate, y: GPUIntegerCoordinate, width: GPUIntegerCoordinate, height: GPUIntegerCoordinate): void;
    /**
     * The **`setStencilReference()`** method of the GPURenderPassEncoder interface sets the stencil reference value using during stencil tests with the "replace" stencil operation (as set in the descriptor of the GPUDevice.createRenderPipeline() method, in the properties defining the various stencil operations).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/setStencilReference)
     */
    setStencilReference(reference: GPUStencilValue): void;
    /**
     * The **`setViewport()`** method of the GPURenderPassEncoder interface sets the viewport used during the rasterization stage to linearly map from normalized device coordinates to viewport coordinates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPassEncoder/setViewport)
     */
    setViewport(x: number, y: number, width: number, height: number, minDepth: number, maxDepth: number): void;
}

declare var GPURenderPassEncoder: {
    prototype: GPURenderPassEncoder;
    new(): GPURenderPassEncoder;
};

/**
 * The **`GPURenderPipeline`** interface of the WebGPU API represents a pipeline that controls the vertex and fragment shader stages and can be used in a GPURenderPassEncoder or GPURenderBundleEncoder.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPURenderPipeline)
 */
interface GPURenderPipeline extends GPUObjectBase, GPUPipelineBase {
}

declare var GPURenderPipeline: {
    prototype: GPURenderPipeline;
    new(): GPURenderPipeline;
};

/**
 * The **`GPUSampler`** interface of the WebGPU API represents an object that can control how shaders transform and filter texture resource data.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSampler)
 */
interface GPUSampler extends GPUObjectBase {
}

declare var GPUSampler: {
    prototype: GPUSampler;
    new(): GPUSampler;
};

/**
 * The **`GPUShaderModule`** interface of the WebGPU API represents an internal shader module object, a container for WGSL shader code that can be submitted to the GPU for execution by a pipeline.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUShaderModule)
 */
interface GPUShaderModule extends GPUObjectBase {
    /**
     * The **`getCompilationInfo()`** method of the GPUShaderModule interface returns a Promise that fulfills with a GPUCompilationInfo object containing messages generated during the GPUShaderModule's compilation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUShaderModule/getCompilationInfo)
     */
    getCompilationInfo(): Promise<GPUCompilationInfo>;
}

declare var GPUShaderModule: {
    prototype: GPUShaderModule;
    new(): GPUShaderModule;
};

/**
 * The **`GPUSupportedFeatures`** interface of the WebGPU API is a Set-like object that describes additional functionality supported by a GPUAdapter.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedFeatures)
 */
interface GPUSupportedFeatures {
    forEach(callbackfn: (value: string, key: string, parent: GPUSupportedFeatures) => void, thisArg?: any): void;
}

declare var GPUSupportedFeatures: {
    prototype: GPUSupportedFeatures;
    new(): GPUSupportedFeatures;
};

/**
 * The **`GPUSupportedLimits`** interface of the WebGPU API describes the limits supported by a GPUAdapter.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits)
 */
interface GPUSupportedLimits {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxBindGroups: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxBindGroupsPlusVertexBuffers: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxBindingsPerBindGroup: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxBufferSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxColorAttachmentBytesPerSample: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxColorAttachments: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxComputeInvocationsPerWorkgroup: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxComputeWorkgroupSizeX: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxComputeWorkgroupSizeY: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxComputeWorkgroupSizeZ: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxComputeWorkgroupStorageSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxComputeWorkgroupsPerDimension: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxDynamicStorageBuffersPerPipelineLayout: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxDynamicUniformBuffersPerPipelineLayout: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxInterStageShaderVariables: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxSampledTexturesPerShaderStage: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxSamplersPerShaderStage: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxStorageBufferBindingSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxStorageBuffersPerShaderStage: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxStorageTexturesPerShaderStage: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxTextureArrayLayers: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxTextureDimension1D: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxTextureDimension2D: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxTextureDimension3D: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxUniformBufferBindingSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxUniformBuffersPerShaderStage: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxVertexAttributes: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxVertexBufferArrayStride: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly maxVertexBuffers: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly minStorageBufferOffsetAlignment: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUSupportedLimits#instance_properties) */
    readonly minUniformBufferOffsetAlignment: number;
}

declare var GPUSupportedLimits: {
    prototype: GPUSupportedLimits;
    new(): GPUSupportedLimits;
};

/**
 * The **`GPUTexture`** interface of the WebGPU API represents a container used to store 1D, 2D, or 3D arrays of data, such as images, to use in GPU rendering operations.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture)
 */
interface GPUTexture extends GPUObjectBase {
    /**
     * The **`depthOrArrayLayers`** read-only property of the GPUTexture interface represents the depth or layer count of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/depthOrArrayLayers)
     */
    readonly depthOrArrayLayers: GPUIntegerCoordinateOut;
    /**
     * The **`dimension`** read-only property of the GPUTexture interface represents the dimension of the set of texels for each GPUTexture subresource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/dimension)
     */
    readonly dimension: GPUTextureDimension;
    /**
     * The **`format`** read-only property of the GPUTexture interface represents the format of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/format)
     */
    readonly format: GPUTextureFormat;
    /**
     * The **`height`** read-only property of the GPUTexture interface represents the height of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/height)
     */
    readonly height: GPUIntegerCoordinateOut;
    /**
     * The **`mipLevelCount`** read-only property of the GPUTexture interface represents the number of mip levels of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/mipLevelCount)
     */
    readonly mipLevelCount: GPUIntegerCoordinateOut;
    /**
     * The **`sampleCount`** read-only property of the GPUTexture interface represents the sample count of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/sampleCount)
     */
    readonly sampleCount: GPUSize32Out;
    /**
     * The **`usage`** read-only property of the GPUTexture interface is the bitwise flags representing the allowed usages of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/usage)
     */
    readonly usage: GPUFlagsConstant;
    /**
     * The **`width`** read-only property of the GPUTexture interface represents the width of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/width)
     */
    readonly width: GPUIntegerCoordinateOut;
    /**
     * The **`createView()`** method of the GPUTexture interface creates a GPUTextureView representing a specific view of the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/createView)
     */
    createView(descriptor?: GPUTextureViewDescriptor): GPUTextureView;
    /**
     * The **`destroy()`** method of the GPUTexture interface destroys the GPUTexture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTexture/destroy)
     */
    destroy(): void;
}

declare var GPUTexture: {
    prototype: GPUTexture;
    new(): GPUTexture;
};

/**
 * The **`GPUTextureView`** interface of the WebGPU API represents a view into a subset of the texture resources defined by a particular GPUTexture.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUTextureView)
 */
interface GPUTextureView extends GPUObjectBase {
}

declare var GPUTextureView: {
    prototype: GPUTextureView;
    new(): GPUTextureView;
};

/**
 * The **`GPUUncapturedErrorEvent`** interface of the WebGPU API is the event object type for the GPUDevice uncapturederror event, used for telemetry and to report unexpected errors.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUUncapturedErrorEvent)
 */
interface GPUUncapturedErrorEvent extends Event {
    /**
     * The **`error`** read-only property of the GPUUncapturedErrorEvent interface is a GPUError object instance providing access to the details of the error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUUncapturedErrorEvent/error)
     */
    readonly error: GPUError;
}

declare var GPUUncapturedErrorEvent: {
    prototype: GPUUncapturedErrorEvent;
    new(type: string, gpuUncapturedErrorEventInitDict: GPUUncapturedErrorEventInit): GPUUncapturedErrorEvent;
};

/**
 * The **`GPUValidationError`** interface of the WebGPU API describes an application error indicating that an operation did not pass the WebGPU API's validation constraints.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GPUValidationError)
 */
interface GPUValidationError extends GPUError {
}

declare var GPUValidationError: {
    prototype: GPUValidationError;
    new(message: string): GPUValidationError;
};

/**
 * The **`GainNode`** interface represents a change in volume. It is an AudioNode audio-processing module that causes a given gain to be applied to the input data before its propagation to the output. A GainNode always has exactly one input and one output, both with the same number of channels.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GainNode)
 */
interface GainNode extends AudioNode {
    /**
     * The **`gain`** property of the GainNode interface is an a-rate AudioParam representing the amount of gain to apply.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GainNode/gain)
     */
    readonly gain: AudioParam;
}

declare var GainNode: {
    prototype: GainNode;
    new(context: BaseAudioContext, options?: GainOptions): GainNode;
};

/**
 * The **`Gamepad`** interface of the Gamepad API defines an individual gamepad or other controller, allowing access to information such as button presses, axis positions, and id.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad)
 */
interface Gamepad {
    /**
     * The **`Gamepad.axes`** property of the Gamepad interface returns an array representing the controls with axes present on the device (e.g., analog thumb sticks).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/axes)
     */
    readonly axes: ReadonlyArray<number>;
    /**
     * The **`buttons`** property of the Gamepad interface returns an array of GamepadButton objects representing the buttons present on the device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/buttons)
     */
    readonly buttons: ReadonlyArray<GamepadButton>;
    /**
     * The **`Gamepad.connected`** property of the Gamepad interface returns a boolean indicating whether the gamepad is still connected to the system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/connected)
     */
    readonly connected: boolean;
    /**
     * The **`Gamepad.id`** property of the Gamepad interface returns a string containing some information about the controller.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/id)
     */
    readonly id: string;
    /**
     * The **`Gamepad.index`** property of the Gamepad interface returns an integer that is auto-incremented to be unique for each device currently connected to the system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/index)
     */
    readonly index: number;
    /**
     * The **`Gamepad.mapping`** property of the Gamepad interface returns a string indicating whether the browser has remapped the controls on the device to a known layout.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/mapping)
     */
    readonly mapping: GamepadMappingType;
    /**
     * The **`Gamepad.timestamp`** property of the Gamepad interface returns a DOMHighResTimeStamp representing the last time the data for this gamepad was updated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/timestamp)
     */
    readonly timestamp: DOMHighResTimeStamp;
    /**
     * The **`vibrationActuator`** read-only property of the Gamepad interface returns a GamepadHapticActuator object, which represents haptic feedback hardware available on the controller.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Gamepad/vibrationActuator)
     */
    readonly vibrationActuator: GamepadHapticActuator;
}

declare var Gamepad: {
    prototype: Gamepad;
    new(): Gamepad;
};

/**
 * The **`GamepadButton`** interface defines an individual button of a gamepad or other controller, allowing access to the current state of different types of buttons available on the control device.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadButton)
 */
interface GamepadButton {
    /**
     * The **`GamepadButton.pressed`** property of the GamepadButton interface returns a boolean indicating whether the button is currently pressed (true) or unpressed (false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadButton/pressed)
     */
    readonly pressed: boolean;
    /**
     * The **`touched`** property of the GamepadButton interface returns a boolean indicating whether a button capable of detecting touch is currently touched (true) or not touched (false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadButton/touched)
     */
    readonly touched: boolean;
    /**
     * The **`GamepadButton.value`** property of the GamepadButton interface returns a double value used to represent the current state of analog buttons on many modern gamepads, such as the triggers.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadButton/value)
     */
    readonly value: number;
}

declare var GamepadButton: {
    prototype: GamepadButton;
    new(): GamepadButton;
};

/**
 * The **`GamepadEvent`** interface of the Gamepad API contains references to gamepads connected to the system, which is what the gamepad events gamepadconnected and gamepaddisconnected are fired in response to.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadEvent)
 */
interface GamepadEvent extends Event {
    /**
     * The **`GamepadEvent.gamepad`** property of the GamepadEvent interface returns a Gamepad object, providing access to the associated gamepad data for fired gamepadconnected and gamepaddisconnected events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadEvent/gamepad)
     */
    readonly gamepad: Gamepad;
}

declare var GamepadEvent: {
    prototype: GamepadEvent;
    new(type: string, eventInitDict?: GamepadEventInit): GamepadEvent;
};

/**
 * The **`GamepadHapticActuator`** interface of the Gamepad API represents hardware in the controller designed to provide haptic feedback to the user (if available), most commonly vibration hardware.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadHapticActuator)
 */
interface GamepadHapticActuator {
    /**
     * The **`playEffect()`** method of the GamepadHapticActuator interface causes the hardware to play a specific vibration effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadHapticActuator/playEffect)
     */
    playEffect(type: GamepadHapticEffectType, params?: GamepadEffectParameters): Promise<GamepadHapticsResult>;
    /**
     * The **`reset()`** method of the GamepadHapticActuator interface stops the hardware from playing an active vibration effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GamepadHapticActuator/reset)
     */
    reset(): Promise<GamepadHapticsResult>;
}

declare var GamepadHapticActuator: {
    prototype: GamepadHapticActuator;
    new(): GamepadHapticActuator;
};

interface GenericTransformStream {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CompressionStream/readable) */
    readonly readable: ReadableStream;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CompressionStream/writable) */
    readonly writable: WritableStream;
}

/**
 * The **`Geolocation`** interface represents an object able to obtain the position of the device programmatically. It gives Web content access to the location of the device. This allows a website or app to offer customized results based on the user's location.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Geolocation)
 */
interface Geolocation {
    /**
     * The **`clearWatch()`** method of the Geolocation interface is used to unregister location/error monitoring handlers previously installed using Geolocation.watchPosition().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Geolocation/clearWatch)
     */
    clearWatch(watchId: number): void;
    /**
     * The **`getCurrentPosition()`** method of the Geolocation interface is used to get the current position of the device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Geolocation/getCurrentPosition)
     */
    getCurrentPosition(successCallback: PositionCallback, errorCallback?: PositionErrorCallback | null, options?: PositionOptions): void;
    /**
     * The **`watchPosition()`** method of the Geolocation interface is used to register a handler function that will be called automatically each time the position of the device changes. You can also, optionally, specify an error handling callback function.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Geolocation/watchPosition)
     */
    watchPosition(successCallback: PositionCallback, errorCallback?: PositionErrorCallback | null, options?: PositionOptions): number;
}

declare var Geolocation: {
    prototype: Geolocation;
    new(): Geolocation;
};

/**
 * The **`GeolocationCoordinates`** interface represents the position and altitude of the device on Earth, as well as the accuracy with which these properties are calculated. The geographic position information is provided in terms of World Geodetic System coordinates (WGS84).
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates)
 */
interface GeolocationCoordinates {
    /**
     * The **`accuracy`** read-only property of the GeolocationCoordinates interface is a strictly positive double representing the accuracy, with a 95% confidence level, of the GeolocationCoordinates.latitude and GeolocationCoordinates.longitude properties expressed in meters.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/accuracy)
     */
    readonly accuracy: number;
    /**
     * The **`altitude`** read-only property of the GeolocationCoordinates interface is a double representing the altitude of the position in meters above the WGS84 ellipsoid (which defines the nominal sea level surface). This value is null if the implementation cannot provide this data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/altitude)
     */
    readonly altitude: number | null;
    /**
     * The **`altitudeAccuracy`** read-only property of the GeolocationCoordinates interface is a strictly positive double representing the accuracy, with a 95% confidence level, of the altitude expressed in meters. This value is null if the implementation doesn't support measuring altitude.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/altitudeAccuracy)
     */
    readonly altitudeAccuracy: number | null;
    /**
     * The **`heading`** read-only property of the GeolocationCoordinates interface is a double representing the direction in which the device is traveling. This value, specified in degrees, indicates how far off from heading due north the device is. 0 degrees represents true north, and the direction is determined clockwise (which means that east is 90 degrees and west is 270 degrees). If GeolocationCoordinates.speed is 0 or the device is not able to provide heading information, heading is null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/heading)
     */
    readonly heading: number | null;
    /**
     * The **`latitude`** read-only property of the GeolocationCoordinates interface is a double representing the latitude of the position in decimal degrees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/latitude)
     */
    readonly latitude: number;
    /**
     * The **`longitude`** read-only property of the GeolocationCoordinates interface is a number which represents the longitude of a geographical position, specified in decimal degrees. Together with a timestamp, given as Unix time in milliseconds, indicating a time of measurement, the GeolocationCoordinates object is part of the GeolocationPosition interface, which is the object type returned by Geolocation API functions that obtain and return a geographical position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/longitude)
     */
    readonly longitude: number;
    /**
     * The **`speed`** read-only property of the GeolocationCoordinates interface is a double representing the velocity of the device in meters per second. This value is null if the implementation is not able to measure it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/speed)
     */
    readonly speed: number | null;
    /**
     * The **`toJSON()`** method of the GeolocationCoordinates interface is a serializer; it returns a JSON representation of the GeolocationCoordinates object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationCoordinates/toJSON)
     */
    toJSON(): any;
}

declare var GeolocationCoordinates: {
    prototype: GeolocationCoordinates;
    new(): GeolocationCoordinates;
};

/**
 * The **`GeolocationPosition`** interface represents the position of the concerned device at a given time. The position, represented by a GeolocationCoordinates object, comprehends the 2D position of the device, on a spheroid representing the Earth, but also its altitude and its speed.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPosition)
 */
interface GeolocationPosition {
    /**
     * The **`coords`** read-only property of the GeolocationPosition interface returns a GeolocationCoordinates object representing a geographic position. It contains the location, that is longitude and latitude on the Earth, the altitude, and the speed of the object concerned, regrouped inside the returned value. It also contains accuracy information about these values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPosition/coords)
     */
    readonly coords: GeolocationCoordinates;
    /**
     * The **`timestamp`** read-only property of the GeolocationPosition interface represents the date and time that the position was acquired by the device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPosition/timestamp)
     */
    readonly timestamp: EpochTimeStamp;
    /**
     * The **`toJSON()`** method of the GeolocationPosition interface is a serializer; it returns a JSON representation of the GeolocationPosition object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPosition/toJSON)
     */
    toJSON(): any;
}

declare var GeolocationPosition: {
    prototype: GeolocationPosition;
    new(): GeolocationPosition;
};

/**
 * The **`GeolocationPositionError`** interface represents the reason of an error occurring when using the geolocating device.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPositionError)
 */
interface GeolocationPositionError {
    /**
     * The **`code`** read-only property of the GeolocationPositionError interface is an unsigned short representing the error code.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPositionError/code)
     */
    readonly code: number;
    /**
     * The **`message`** read-only property of the GeolocationPositionError interface returns a human-readable string describing the details of the error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/GeolocationPositionError/message)
     */
    readonly message: string;
    readonly PERMISSION_DENIED: 1;
    readonly POSITION_UNAVAILABLE: 2;
    readonly TIMEOUT: 3;
}

declare var GeolocationPositionError: {
    prototype: GeolocationPositionError;
    new(): GeolocationPositionError;
    readonly PERMISSION_DENIED: 1;
    readonly POSITION_UNAVAILABLE: 2;
    readonly TIMEOUT: 3;
};

interface GlobalEventHandlersEventMap {
    "abort": UIEvent;
    "animationcancel": AnimationEvent;
    "animationend": AnimationEvent;
    "animationiteration": AnimationEvent;
    "animationstart": AnimationEvent;
    "auxclick": PointerEvent;
    "beforeinput": InputEvent;
    "beforematch": Event;
    "beforetoggle": ToggleEvent;
    "blur": FocusEvent;
    "cancel": Event;
    "canplay": Event;
    "canplaythrough": Event;
    "change": Event;
    "click": PointerEvent;
    "close": Event;
    "command": Event;
    "compositionend": CompositionEvent;
    "compositionstart": CompositionEvent;
    "compositionupdate": CompositionEvent;
    "contextlost": Event;
    "contextmenu": PointerEvent;
    "contextrestored": Event;
    "copy": ClipboardEvent;
    "cuechange": Event;
    "cut": ClipboardEvent;
    "dblclick": MouseEvent;
    "drag": DragEvent;
    "dragend": DragEvent;
    "dragenter": DragEvent;
    "dragleave": DragEvent;
    "dragover": DragEvent;
    "dragstart": DragEvent;
    "drop": DragEvent;
    "durationchange": Event;
    "emptied": Event;
    "ended": Event;
    "error": ErrorEvent;
    "focus": FocusEvent;
    "focusin": FocusEvent;
    "focusout": FocusEvent;
    "formdata": FormDataEvent;
    "gotpointercapture": PointerEvent;
    "input": InputEvent;
    "invalid": Event;
    "keydown": KeyboardEvent;
    "keypress": KeyboardEvent;
    "keyup": KeyboardEvent;
    "load": Event;
    "loadeddata": Event;
    "loadedmetadata": Event;
    "loadstart": Event;
    "lostpointercapture": PointerEvent;
    "mousedown": MouseEvent;
    "mouseenter": MouseEvent;
    "mouseleave": MouseEvent;
    "mousemove": MouseEvent;
    "mouseout": MouseEvent;
    "mouseover": MouseEvent;
    "mouseup": MouseEvent;
    "paste": ClipboardEvent;
    "pause": Event;
    "play": Event;
    "playing": Event;
    "pointercancel": PointerEvent;
    "pointerdown": PointerEvent;
    "pointerenter": PointerEvent;
    "pointerleave": PointerEvent;
    "pointermove": PointerEvent;
    "pointerout": PointerEvent;
    "pointerover": PointerEvent;
    "pointerrawupdate": Event;
    "pointerup": PointerEvent;
    "progress": ProgressEvent;
    "ratechange": Event;
    "reset": Event;
    "resize": UIEvent;
    "scroll": Event;
    "scrollend": Event;
    "securitypolicyviolation": SecurityPolicyViolationEvent;
    "seeked": Event;
    "seeking": Event;
    "select": Event;
    "selectionchange": Event;
    "selectstart": Event;
    "slotchange": Event;
    "stalled": Event;
    "submit": SubmitEvent;
    "suspend": Event;
    "timeupdate": Event;
    "toggle": ToggleEvent;
    "touchcancel": TouchEvent;
    "touchend": TouchEvent;
    "touchmove": TouchEvent;
    "touchstart": TouchEvent;
    "transitioncancel": TransitionEvent;
    "transitionend": TransitionEvent;
    "transitionrun": TransitionEvent;
    "transitionstart": TransitionEvent;
    "volumechange": Event;
    "waiting": Event;
    "webkitanimationend": Event;
    "webkitanimationiteration": Event;
    "webkitanimationstart": Event;
    "webkittransitionend": Event;
    "wheel": WheelEvent;
}

interface GlobalEventHandlers {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/abort_event) */
    onabort: ((this: GlobalEventHandlers, ev: UIEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationcancel_event) */
    onanimationcancel: ((this: GlobalEventHandlers, ev: AnimationEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationend_event) */
    onanimationend: ((this: GlobalEventHandlers, ev: AnimationEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationiteration_event) */
    onanimationiteration: ((this: GlobalEventHandlers, ev: AnimationEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationstart_event) */
    onanimationstart: ((this: GlobalEventHandlers, ev: AnimationEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/auxclick_event) */
    onauxclick: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/beforeinput_event) */
    onbeforeinput: ((this: GlobalEventHandlers, ev: InputEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/beforematch_event) */
    onbeforematch: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/beforetoggle_event) */
    onbeforetoggle: ((this: GlobalEventHandlers, ev: ToggleEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/blur_event) */
    onblur: ((this: GlobalEventHandlers, ev: FocusEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/cancel_event) */
    oncancel: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/canplay_event) */
    oncanplay: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/canplaythrough_event) */
    oncanplaythrough: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/change_event) */
    onchange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/click_event) */
    onclick: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/close_event) */
    onclose: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/command_event) */
    oncommand: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/contextlost_event) */
    oncontextlost: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/contextmenu_event) */
    oncontextmenu: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/contextrestored_event) */
    oncontextrestored: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/copy_event) */
    oncopy: ((this: GlobalEventHandlers, ev: ClipboardEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLTrackElement/cuechange_event) */
    oncuechange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/cut_event) */
    oncut: ((this: GlobalEventHandlers, ev: ClipboardEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/dblclick_event) */
    ondblclick: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/drag_event) */
    ondrag: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragend_event) */
    ondragend: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragenter_event) */
    ondragenter: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragleave_event) */
    ondragleave: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragover_event) */
    ondragover: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dragstart_event) */
    ondragstart: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/drop_event) */
    ondrop: ((this: GlobalEventHandlers, ev: DragEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/durationchange_event) */
    ondurationchange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/emptied_event) */
    onemptied: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/ended_event) */
    onended: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/error_event) */
    onerror: OnErrorEventHandler;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/focus_event) */
    onfocus: ((this: GlobalEventHandlers, ev: FocusEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/formdata_event) */
    onformdata: ((this: GlobalEventHandlers, ev: FormDataEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/gotpointercapture_event) */
    ongotpointercapture: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/input_event) */
    oninput: ((this: GlobalEventHandlers, ev: InputEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/invalid_event) */
    oninvalid: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/keydown_event) */
    onkeydown: ((this: GlobalEventHandlers, ev: KeyboardEvent) => any) | null;
    /**
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/keypress_event)
     */
    onkeypress: ((this: GlobalEventHandlers, ev: KeyboardEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/keyup_event) */
    onkeyup: ((this: GlobalEventHandlers, ev: KeyboardEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/load_event) */
    onload: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loadeddata_event) */
    onloadeddata: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loadedmetadata_event) */
    onloadedmetadata: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/loadstart_event) */
    onloadstart: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/lostpointercapture_event) */
    onlostpointercapture: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mousedown_event) */
    onmousedown: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseenter_event) */
    onmouseenter: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseleave_event) */
    onmouseleave: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mousemove_event) */
    onmousemove: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseout_event) */
    onmouseout: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseover_event) */
    onmouseover: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/mouseup_event) */
    onmouseup: ((this: GlobalEventHandlers, ev: MouseEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/paste_event) */
    onpaste: ((this: GlobalEventHandlers, ev: ClipboardEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/pause_event) */
    onpause: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/play_event) */
    onplay: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/playing_event) */
    onplaying: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointercancel_event) */
    onpointercancel: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerdown_event) */
    onpointerdown: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerenter_event) */
    onpointerenter: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerleave_event) */
    onpointerleave: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointermove_event) */
    onpointermove: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerout_event) */
    onpointerout: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerover_event) */
    onpointerover: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerrawupdate_event)
     */
    onpointerrawupdate: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/pointerup_event) */
    onpointerup: ((this: GlobalEventHandlers, ev: PointerEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/progress_event) */
    onprogress: ((this: GlobalEventHandlers, ev: ProgressEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/ratechange_event) */
    onratechange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/reset_event) */
    onreset: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLVideoElement/resize_event) */
    onresize: ((this: GlobalEventHandlers, ev: UIEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/scroll_event) */
    onscroll: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/scrollend_event) */
    onscrollend: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/securitypolicyviolation_event) */
    onsecuritypolicyviolation: ((this: GlobalEventHandlers, ev: SecurityPolicyViolationEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/seeked_event) */
    onseeked: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/seeking_event) */
    onseeking: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLInputElement/select_event) */
    onselect: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/selectionchange_event) */
    onselectionchange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/selectstart_event) */
    onselectstart: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLSlotElement/slotchange_event) */
    onslotchange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/stalled_event) */
    onstalled: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/submit_event) */
    onsubmit: ((this: GlobalEventHandlers, ev: SubmitEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/suspend_event) */
    onsuspend: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/timeupdate_event) */
    ontimeupdate: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/toggle_event) */
    ontoggle: ((this: GlobalEventHandlers, ev: ToggleEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchcancel_event) */
    ontouchcancel?: ((this: GlobalEventHandlers, ev: TouchEvent) => any) | null | undefined;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchend_event) */
    ontouchend?: ((this: GlobalEventHandlers, ev: TouchEvent) => any) | null | undefined;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchmove_event) */
    ontouchmove?: ((this: GlobalEventHandlers, ev: TouchEvent) => any) | null | undefined;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/touchstart_event) */
    ontouchstart?: ((this: GlobalEventHandlers, ev: TouchEvent) => any) | null | undefined;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitioncancel_event) */
    ontransitioncancel: ((this: GlobalEventHandlers, ev: TransitionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionend_event) */
    ontransitionend: ((this: GlobalEventHandlers, ev: TransitionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionrun_event) */
    ontransitionrun: ((this: GlobalEventHandlers, ev: TransitionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionstart_event) */
    ontransitionstart: ((this: GlobalEventHandlers, ev: TransitionEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/volumechange_event) */
    onvolumechange: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLMediaElement/waiting_event) */
    onwaiting: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /**
     * @deprecated This is a legacy alias of `onanimationend`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationend_event)
     */
    onwebkitanimationend: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /**
     * @deprecated This is a legacy alias of `onanimationiteration`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationiteration_event)
     */
    onwebkitanimationiteration: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /**
     * @deprecated This is a legacy alias of `onanimationstart`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/animationstart_event)
     */
    onwebkitanimationstart: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /**
     * @deprecated This is a legacy alias of `ontransitionend`.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/transitionend_event)
     */
    onwebkittransitionend: ((this: GlobalEventHandlers, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/wheel_event) */
    onwheel: ((this: GlobalEventHandlers, ev: WheelEvent) => any) | null;
    addEventListener<K extends keyof GlobalEventHandlersEventMap>(type: K, listener: (this: GlobalEventHandlers, ev: GlobalEventHandlersEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof GlobalEventHandlersEventMap>(type: K, listener: (this: GlobalEventHandlers, ev: GlobalEventHandlersEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/**
 * The **`HTMLAllCollection`** interface represents a collection of all of the document's elements, accessible by index (like an array) and by the element's id. It is returned by the document.all property.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAllCollection)
 */
interface HTMLAllCollection {
    /**
     * The **`HTMLAllCollection.length`** property returns the number of items in this HTMLAllCollection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAllCollection/length)
     */
    readonly length: number;
    /**
     * The **`item()`** method of the HTMLAllCollection interface returns the element located at the specified offset into the collection, or the element with the specified value for its id or name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAllCollection/item)
     */
    item(nameOrIndex?: string): HTMLCollection | Element | null;
    /**
     * The **`namedItem()`** method of the HTMLAllCollection interface returns the first Element in the collection whose id or name attribute matches the specified name, or null if no element matches.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAllCollection/namedItem)
     */
    namedItem(name: string): HTMLCollection | Element | null;
    [index: number]: Element;
}

declare var HTMLAllCollection: {
    prototype: HTMLAllCollection;
    new(): HTMLAllCollection;
};

/**
 * The **`HTMLAnchorElement`** interface represents hyperlink elements and provides special properties and methods (beyond those of the regular HTMLElement object interface that they inherit from) for manipulating the layout and presentation of such elements. This interface corresponds to <a> element; not to be confused with <link>, which is represented by HTMLLinkElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement)
 */
interface HTMLAnchorElement extends HTMLElement, HTMLHyperlinkElementUtils {
    /** @deprecated */
    charset: string;
    /** @deprecated */
    coords: string;
    /**
     * The **`HTMLAnchorElement.download`** property is a string indicating that the linked resource is intended to be downloaded rather than displayed in the browser. The value, if any, specifies the default file name for use in labeling the resource in a local file system. If the name is not a valid file name in the underlying OS, the browser will adjust it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/download)
     */
    download: string;
    /**
     * The **`hreflang`** property of the HTMLAnchorElement interface is a string that is the language of the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/hreflang)
     */
    hreflang: string;
    /** @deprecated */
    name: string;
    /**
     * The **`ping`** property of the HTMLAnchorElement interface is a space-separated list of URLs. When the link is followed, the browser will send POST requests with the body PING to the URLs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/ping)
     */
    ping: string;
    /**
     * The **`HTMLAnchorElement.referrerPolicy`** property reflect the HTML referrerpolicy attribute of the <a> element defining which referrer is sent when fetching the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/referrerPolicy)
     */
    referrerPolicy: string;
    /**
     * The **`HTMLAnchorElement.rel`** property reflects the rel attribute. It is a string containing a space-separated list of link types indicating the relationship between the resource represented by the <a> element and the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/rel)
     */
    rel: string;
    /**
     * The read-only **`relList`** property of the HTMLAnchorElement returns a live DOMTokenList object containing the set of link types indicating the relationship between the resource represented by the <a> element and the current document. It reflects the <a> element's rel content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/relList)
     */
    get relList(): DOMTokenList;
    set relList(value: string);
    /** @deprecated */
    rev: string;
    /** @deprecated */
    shape: string;
    /**
     * The **`target`** property of the HTMLAnchorElement interface is a string that indicates where to display the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/target)
     */
    target: string;
    /**
     * The **`text`** property of the HTMLAnchorElement represents the text inside the element. This property represents the same information as Node.textContent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/text)
     */
    text: string;
    /**
     * The **`type`** property of the HTMLAnchorElement interface is a string that indicates the MIME type of the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAnchorElement/type)
     */
    type: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLAnchorElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLAnchorElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLAnchorElement: {
    prototype: HTMLAnchorElement;
    new(): HTMLAnchorElement;
};

/**
 * The **`HTMLAreaElement`** interface provides special properties and methods (beyond those of the regular object HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of <area> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement)
 */
interface HTMLAreaElement extends HTMLElement, HTMLHyperlinkElementUtils {
    /**
     * The **`alt`** property of the HTMLAreaElement interface specifies the text of the hyperlink, defining the textual label for an image map's link. It reflects the <area> element's alt attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/alt)
     */
    alt: string;
    /**
     * The **`coords`** property of the HTMLAreaElement interface specifies the coordinates of the element's shape as a list of floating-point numbers. It reflects the <area> element's coords attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/coords)
     */
    coords: string;
    /**
     * The **`download`** property of the HTMLAreaElement interface is a string indicating that the linked resource is intended to be downloaded rather than displayed in the browser. The value represent the proposed name of the file. If the name is not a valid filename of the underlying OS, browser will adjust it accordingly.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/download)
     */
    download: string;
    /** @deprecated */
    noHref: boolean;
    /**
     * The **`ping`** property of the HTMLAreaElement interface is a space-separated list of URLs. When the link is followed, the browser will send POST requests with the body PING to the URLs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/ping)
     */
    ping: string;
    /**
     * The **`HTMLAreaElement.referrerPolicy`** property reflect the HTML referrerpolicy attribute of the <area> element defining which referrer is sent when fetching the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/referrerPolicy)
     */
    referrerPolicy: string;
    /**
     * The **`HTMLAreaElement.rel`** property reflects the rel attribute. It is a string containing a space-separated list of link types indicating the relationship between the resource represented by the <area> element and the current document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/rel)
     */
    rel: string;
    /**
     * The read-only **`relList`** property of the HTMLAreaElement returns a live DOMTokenList object containing the set of link types indicating the relationship between the resource represented by the <area> element and the current document. It reflects the <area> element's rel content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/relList)
     */
    get relList(): DOMTokenList;
    set relList(value: string);
    /**
     * The **`shape`** property of the HTMLAreaElement interface specifies the shape of an image map area. It reflects the <area> element's shape attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/shape)
     */
    shape: string;
    /**
     * The **`target`** property of the HTMLAreaElement interface is a string that indicates where to display the linked resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAreaElement/target)
     */
    target: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLAreaElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLAreaElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLAreaElement: {
    prototype: HTMLAreaElement;
    new(): HTMLAreaElement;
};

/**
 * The **`HTMLAudioElement`** interface provides access to the properties of <audio> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLAudioElement)
 */
interface HTMLAudioElement extends HTMLMediaElement {
    addEventListener<K extends keyof HTMLMediaElementEventMap>(type: K, listener: (this: HTMLAudioElement, ev: HTMLMediaElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLMediaElementEventMap>(type: K, listener: (this: HTMLAudioElement, ev: HTMLMediaElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLAudioElement: {
    prototype: HTMLAudioElement;
    new(): HTMLAudioElement;
};

/**
 * The **`HTMLBRElement`** interface represents an HTML line break element (<br>). It inherits from HTMLElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLBRElement)
 */
interface HTMLBRElement extends HTMLElement {
    /** @deprecated */
    clear: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLBRElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLBRElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLBRElement: {
    prototype: HTMLBRElement;
    new(): HTMLBRElement;
};

/**
 * The **`HTMLBaseElement`** interface contains the base URI for a document. This object inherits all of the properties and methods as described in the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLBaseElement)
 */
interface HTMLBaseElement extends HTMLElement {
    /**
     * The **`href`** property of the HTMLBaseElement interface contains a string that is the URL to use as the base for relative URLs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLBaseElement/href)
     */
    href: string;
    /**
     * The **`target`** property of the HTMLBaseElement interface is a string that represents the default target tab to show the resulting output for hyperlinks and form elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLBaseElement/target)
     */
    target: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLBaseElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLBaseElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLBaseElement: {
    prototype: HTMLBaseElement;
    new(): HTMLBaseElement;
};

interface HTMLBodyElementEventMap extends HTMLElementEventMap, WindowEventHandlersEventMap {
}

/**
 * The **`HTMLBodyElement`** interface provides special properties (beyond those inherited from the regular HTMLElement interface) for manipulating <body> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLBodyElement)
 */
interface HTMLBodyElement extends HTMLElement, WindowEventHandlers {
    /** @deprecated */
    aLink: string;
    /** @deprecated */
    background: string;
    /** @deprecated */
    bgColor: string;
    /** @deprecated */
    link: string;
    /** @deprecated */
    text: string;
    /** @deprecated */
    vLink: string;
    addEventListener<K extends keyof HTMLBodyElementEventMap>(type: K, listener: (this: HTMLBodyElement, ev: HTMLBodyElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLBodyElementEventMap>(type: K, listener: (this: HTMLBodyElement, ev: HTMLBodyElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLBodyElement: {
    prototype: HTMLBodyElement;
    new(): HTMLBodyElement;
};

/**
 * The **`HTMLButtonElement`** interface provides properties and methods (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating <button> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement)
 */
interface HTMLButtonElement extends HTMLElement, PopoverTargetAttributes {
    /**
     * The **`command`** property of the HTMLButtonElement interface gets and sets the action to be performed on an element being controlled by this button. For this to have an effect, commandfor must be set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/command)
     */
    command: string;
    /**
     * The **`commandForElement`** property of the HTMLButtonElement interface gets and sets the element to control via a button.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/commandForElement)
     */
    commandForElement: Element | null;
    /**
     * The **`HTMLButtonElement.disabled`** property indicates whether the control is disabled, meaning that it does not accept any clicks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`form`** read-only property of the HTMLButtonElement interface returns an HTMLFormElement object that owns this <button>, or null if this button is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`formAction`** property of the HTMLButtonElement interface is the URL of the program that is executed on the server when the form that owns this control is submitted. It reflects the value of the <button>'s formaction attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/formAction)
     */
    formAction: string;
    /**
     * The **`formEnctype`** property of the HTMLButtonElement interface is the MIME type of the content sent to the server when the form is submitted. It reflects the value of the <button>'s formenctype attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/formEnctype)
     */
    formEnctype: string;
    /**
     * The **`formMethod`** property of the HTMLButtonElement interface is the HTTP method used to submit the <form> if the <button> element is the control that submits the form. It reflects the value of the <button>'s formmethod attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/formMethod)
     */
    formMethod: string;
    /**
     * The **`formNoValidate`** property of the HTMLButtonElement interface is a boolean value indicating if the <form> will bypass constraint validation when submitted via the <button>. It reflects the <button> element's formnovalidate attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/formNoValidate)
     */
    formNoValidate: boolean;
    /**
     * The **`formTarget`** property of the HTMLButtonElement interface is the tab, window, or iframe where the response of the submitted <form> is to be displayed. It reflects the value of the <button> element's formtarget attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/formTarget)
     */
    formTarget: string;
    /**
     * The **`HTMLButtonElement.labels`** read-only property returns a NodeList of the <label> elements associated with the <button> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/labels)
     */
    readonly labels: NodeListOf<HTMLLabelElement>;
    /**
     * The **`name`** property of the HTMLButtonElement interface indicates the name of the <button> element or the empty string if the element has no name. It reflects the element's name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/name)
     */
    name: string;
    /**
     * The **`type`** property of the HTMLButtonElement interface is a string that indicates the behavior type of the <button> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/type)
     */
    type: "submit" | "reset" | "button";
    /**
     * The **`validationMessage`** read-only property of the HTMLButtonElement interface returns a string representing a localized message that describes the validation constraints that the <button> control does not satisfy (if any). This is the empty string if the control is not a candidate for constraint validation (the <button>'s type is button or reset), or it satisfies its constraints.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLButtonElement interface returns a ValidityState object that represents the validity states this element is in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`value`** property of the HTMLButtonElement interface represents the value of the <button> element as a string, or the empty string if no value is set. It reflects the element's value attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/value)
     */
    value: string;
    /**
     * The **`willValidate`** read-only property of the HTMLButtonElement interface indicates whether the <button> element is a candidate for constraint validation. It is false if any conditions bar it from constraint validation, including:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`checkValidity()`** method of the HTMLButtonElement interface returns a boolean value which indicates if the element meets any constraint validation rules applied to it. If false, the method also fires an invalid event on the element. Because there's no default browser behavior for checkValidity(), canceling this invalid event has no effect. It always returns true if the <button> element's type is "button" or "reset", because such buttons are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the HTMLButtonElement interface performs the same validity checking steps as the checkValidity() method. In addition, if the invalid event is not canceled, the browser displays the problem to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`setCustomValidity()`** method of the HTMLButtonElement interface sets the custom validity message for the <button> element. Use the empty string to indicate that the element does not have a custom validity error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLButtonElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLButtonElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLButtonElement: {
    prototype: HTMLButtonElement;
    new(): HTMLButtonElement;
};

/**
 * The **`HTMLCanvasElement`** interface provides properties and methods for manipulating the layout and presentation of <canvas> elements. The HTMLCanvasElement interface also inherits the properties and methods of the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement)
 */
interface HTMLCanvasElement extends HTMLElement {
    /**
     * The **`HTMLCanvasElement.height`** property is a positive integer reflecting the height HTML attribute of the <canvas> element interpreted in CSS pixels. When the attribute is not specified, or if it is set to an invalid value, like a negative, the default value of 150 is used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/height)
     */
    height: number;
    /**
     * The **`HTMLCanvasElement.width`** property is a positive integer reflecting the width HTML attribute of the <canvas> element interpreted in CSS pixels. When the attribute is not specified, or if it is set to an invalid value, like a negative, the default value of 300 is used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/width)
     */
    width: number;
    /**
     * The **`captureStream()`** method of the HTMLCanvasElement interface returns a MediaStream which includes a CanvasCaptureMediaStreamTrack containing a real-time video capture of the canvas's contents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/captureStream)
     */
    captureStream(frameRequestRate?: number): MediaStream;
    /**
     * The **`HTMLCanvasElement.getContext()`** method returns a drawing context on the canvas, or null if the context identifier is not supported, or the canvas has already been set to a different context mode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/getContext)
     */
    getContext(contextId: "2d", options?: CanvasRenderingContext2DSettings): CanvasRenderingContext2D | null;
    getContext(contextId: "bitmaprenderer", options?: ImageBitmapRenderingContextSettings): ImageBitmapRenderingContext | null;
    getContext(contextId: "webgl", options?: WebGLContextAttributes): WebGLRenderingContext | null;
    getContext(contextId: "webgl2", options?: WebGLContextAttributes): WebGL2RenderingContext | null;
    getContext(contextId: string, options?: any): RenderingContext | null;
    /**
     * The **`HTMLCanvasElement.toBlob()`** method creates a Blob object representing the image contained in the canvas. This file may be cached on the disk or stored in memory at the discretion of the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/toBlob)
     */
    toBlob(callback: BlobCallback, type?: string, quality?: number): void;
    /**
     * The **`HTMLCanvasElement.toDataURL()`** method returns a data URL containing a representation of the image in the format specified by the type parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/toDataURL)
     */
    toDataURL(type?: string, quality?: number): string;
    /**
     * The **`HTMLCanvasElement.transferControlToOffscreen()`** method transfers control to an OffscreenCanvas object, either on the main thread or on a worker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCanvasElement/transferControlToOffscreen)
     */
    transferControlToOffscreen(): OffscreenCanvas;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLCanvasElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLCanvasElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLCanvasElement: {
    prototype: HTMLCanvasElement;
    new(): HTMLCanvasElement;
};

/**
 * The **`HTMLCollection`** interface represents a generic collection (array-like object similar to arguments) of elements (in document order) and offers methods and properties for selecting from the list.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCollection)
 */
interface HTMLCollectionBase {
    /**
     * The **`HTMLCollection.length`** property returns the number of items in a HTMLCollection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCollection/length)
     */
    readonly length: number;
    /**
     * The HTMLCollection method **`item()`** returns the element located at the specified offset into the collection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCollection/item)
     */
    item(index: number): Element | null;
    [index: number]: Element;
}

interface HTMLCollection extends HTMLCollectionBase {
    /**
     * The **`namedItem()`** method of the HTMLCollection interface returns the first Element in the collection whose id or name attribute match the specified name, or null if no element matches.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLCollection/namedItem)
     */
    namedItem(name: string): Element | null;
}

declare var HTMLCollection: {
    prototype: HTMLCollection;
    new(): HTMLCollection;
};

interface HTMLCollectionOf<T extends Element> extends HTMLCollectionBase {
    item(index: number): T | null;
    namedItem(name: string): T | null;
    [index: number]: T;
}

/**
 * The **`HTMLDListElement`** interface provides special properties (beyond those of the regular HTMLElement interface it also has available to it by inheritance) for manipulating definition list (<dl>) elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDListElement)
 */
interface HTMLDListElement extends HTMLElement {
    /**
     * The **`compact`** property of the HTMLDListElement interface indicates that spacing between list items should be reduced. The exact handling of the compact attribute is browser-specific. Instead of using this property, consider using CSS line-height instead.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDListElement/compact)
     */
    compact: boolean;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDListElement: {
    prototype: HTMLDListElement;
    new(): HTMLDListElement;
};

/**
 * The **`HTMLDataElement`** interface provides special properties (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating <data> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDataElement)
 */
interface HTMLDataElement extends HTMLElement {
    /**
     * The **`value`** property of the HTMLDataElement interface returns a string reflecting the value HTML attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDataElement/value)
     */
    value: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDataElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDataElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDataElement: {
    prototype: HTMLDataElement;
    new(): HTMLDataElement;
};

/**
 * The **`HTMLDataListElement`** interface provides special properties (beyond the HTMLElement object interface it also has available to it by inheritance) to manipulate <datalist> elements and their content.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDataListElement)
 */
interface HTMLDataListElement extends HTMLElement {
    /**
     * The **`options`** read-only property of the HTMLDataListElement interface returns an HTMLCollection of HTMLOptionElement elements contained in a <datalist>. The descendant <option> elements provide predefined options for the <input> control associated with the <datalist>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDataListElement/options)
     */
    readonly options: HTMLCollectionOf<HTMLOptionElement>;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDataListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDataListElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDataListElement: {
    prototype: HTMLDataListElement;
    new(): HTMLDataListElement;
};

/**
 * The **`HTMLDetailsElement`** interface provides special properties (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating <details> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDetailsElement)
 */
interface HTMLDetailsElement extends HTMLElement {
    /**
     * The **`name`** property of the HTMLDetailsElement interface reflects the name attribute of <details> elements. It enables multiple <details> elements to be connected together, where only one for the <details> elements can be open at once. This allows developers to easily create UI features such as accordions without scripting.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDetailsElement/name)
     */
    name: string;
    /**
     * The **`open`** property of the HTMLDetailsElement interface is a boolean value reflecting the open HTML attribute, indicating whether the <details>'s contents (not counting the <summary>) is to be shown to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDetailsElement/open)
     */
    open: boolean;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDetailsElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDetailsElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDetailsElement: {
    prototype: HTMLDetailsElement;
    new(): HTMLDetailsElement;
};

/**
 * The **`HTMLDialogElement`** interface provides methods to manipulate <dialog> elements. It inherits properties and methods from the HTMLElement interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement)
 */
interface HTMLDialogElement extends HTMLElement {
    /**
     * The **`closedBy`** property of the HTMLDialogElement interface indicates the types of user actions that can be used to close the associated <dialog> element. It sets or returns the dialog's closedby attribute value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/closedBy)
     */
    closedBy: string;
    /**
     * The **`open`** property of the HTMLDialogElement interface is a boolean value reflecting the open HTML attribute, indicating whether the <dialog> is available for interaction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/open)
     */
    open: boolean;
    /**
     * The **`returnValue`** property of the HTMLDialogElement interface is a string representing the return value for a <dialog> element when it's closed. You can set the value directly (dialog.returnValue = "result") or by providing the value as a string argument to close() or requestClose().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/returnValue)
     */
    returnValue: string;
    /**
     * The **`close()`** method of the HTMLDialogElement interface closes the <dialog>. An optional string may be passed as an argument, updating the returnValue of the dialog.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/close)
     */
    close(returnValue?: string): void;
    /**
     * The **`requestClose()`** method of the HTMLDialogElement interface requests to close the <dialog>. An optional string may be passed as an argument, updating the returnValue of the dialog.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/requestClose)
     */
    requestClose(returnValue?: string): void;
    /**
     * The **`show()`** method of the HTMLDialogElement interface displays the dialog as a non-modal dialog.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/show)
     */
    show(): void;
    /**
     * The **`showModal()`** method of the HTMLDialogElement interface displays the dialog as a modal dialog, over the top of any other dialogs or elements that might be visible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDialogElement/showModal)
     */
    showModal(): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDialogElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDialogElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDialogElement: {
    prototype: HTMLDialogElement;
    new(): HTMLDialogElement;
};

/** @deprecated */
interface HTMLDirectoryElement extends HTMLElement {
    /** @deprecated */
    compact: boolean;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDirectoryElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDirectoryElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var HTMLDirectoryElement: {
    prototype: HTMLDirectoryElement;
    new(): HTMLDirectoryElement;
};

/**
 * The **`HTMLDivElement`** interface provides special properties (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating <div> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLDivElement)
 */
interface HTMLDivElement extends HTMLElement {
    /** @deprecated */
    align: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDivElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLDivElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDivElement: {
    prototype: HTMLDivElement;
    new(): HTMLDivElement;
};

/** For historical reasons, Window objects have a **`window.HTMLDocument`** property whose value is the Document interface. So you can think of HTMLDocument as an alias for Document, and you can find documentation for HTMLDocument members under the documentation for the Document interface. */
interface HTMLDocument extends Document {
    addEventListener<K extends keyof DocumentEventMap>(type: K, listener: (this: HTMLDocument, ev: DocumentEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof DocumentEventMap>(type: K, listener: (this: HTMLDocument, ev: DocumentEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLDocument: {
    prototype: HTMLDocument;
    new(): HTMLDocument;
};

interface HTMLElementEventMap extends ElementEventMap, GlobalEventHandlersEventMap {
}

/**
 * The **`HTMLElement`** interface represents any HTML element. Some elements directly implement this interface, while others implement it via an interface that inherits it.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement)
 */
interface HTMLElement extends Element, ElementCSSInlineStyle, ElementContentEditable, GlobalEventHandlers, HTMLOrSVGElement {
    /**
     * The **`HTMLElement.accessKey`** property sets the keystroke which a user can press to jump to a given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/accessKey)
     */
    accessKey: string;
    /**
     * The **`HTMLElement.accessKeyLabel`** read-only property returns a string containing the element's browser-assigned access key (if any); otherwise it returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/accessKeyLabel)
     */
    readonly accessKeyLabel: string;
    /**
     * The **`autocapitalize`** property of the HTMLElement interface represents the element's capitalization behavior for user input. It is available on all HTML elements, though it doesn't affect all of them, including:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/autocapitalize)
     */
    autocapitalize: string;
    /**
     * The **`autocorrect`** property of the HTMLElement interface controls whether or not autocorrection of editable text is enabled for spelling and/or punctuation errors.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/autocorrect)
     */
    autocorrect: boolean;
    /**
     * The **`HTMLElement.dir`** property indicates the text writing directionality of the content of the current element. It reflects the element's dir attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/dir)
     */
    dir: string;
    /**
     * The **`draggable`** property of the HTMLElement interface gets and sets a Boolean primitive indicating if the element is draggable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/draggable)
     */
    draggable: boolean;
    /**
     * The HTMLElement property **`hidden`** reflects the value of the element's hidden attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/hidden)
     */
    hidden: boolean | "until-found";
    /**
     * The HTMLElement property **`inert`** reflects the value of the element's inert attribute. It is a boolean value that, when present, makes the browser "ignore" user input events for the element, including focus events and events from assistive technologies. The browser may also ignore page search and text selection in the element. This can be useful when building UIs such as modals where you would want to "trap" the focus inside the modal when it's visible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/inert)
     */
    inert: boolean;
    /**
     * The **`innerText`** property of the HTMLElement interface represents the rendered text content of a node and its descendants.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/innerText)
     */
    innerText: string;
    /**
     * The **`lang`** property of the HTMLElement interface indicates the base language of an element's attribute values and text content, in the form of a BCP 47 language tag. It reflects the element's lang attribute; the xml:lang attribute does not affect this property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/lang)
     */
    lang: string;
    /**
     * The **`offsetHeight`** read-only property of the HTMLElement interface returns the height of an element, including vertical padding and borders, as an integer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/offsetHeight)
     */
    readonly offsetHeight: number;
    /**
     * The **`offsetLeft`** read-only property of the HTMLElement interface returns the number of pixels that the upper left corner of the current element is offset to the left within the HTMLElement.offsetParent node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/offsetLeft)
     */
    readonly offsetLeft: number;
    /**
     * The **`HTMLElement.offsetParent`** read-only property returns a reference to the element which is the closest (nearest in the containment hierarchy) positioned ancestor element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/offsetParent)
     */
    readonly offsetParent: Element | null;
    /**
     * The **`offsetTop`** read-only property of the HTMLElement interface returns the distance from the outer border of the current element (including its margin) to the top padding edge of the offsetParent, the closest positioned ancestor element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/offsetTop)
     */
    readonly offsetTop: number;
    /**
     * The **`offsetWidth`** read-only property of the HTMLElement interface returns the layout width of an element as an integer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/offsetWidth)
     */
    readonly offsetWidth: number;
    /**
     * The **`outerText`** property of the HTMLElement interface returns the same value as HTMLElement.innerText. When used as a setter it replaces the whole current node with the given text (this differs from innerText, which replaces the content inside the current node).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/outerText)
     */
    outerText: string;
    /**
     * The **`popover`** property of the HTMLElement interface gets and sets an element's popover state via JavaScript ("auto", "hint", or "manual"), and can be used for feature detection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/popover)
     */
    popover: string | null;
    /**
     * The **`spellcheck`** property of the HTMLElement interface represents a boolean value that controls the spell-checking hint. It is available on all HTML elements, though it doesn't affect all of them.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/spellcheck)
     */
    spellcheck: boolean;
    /**
     * The **`HTMLElement.title`** property represents the title of the element: the text usually displayed in a 'tooltip' popup when the mouse is over the node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/title)
     */
    title: string;
    /**
     * The **`translate`** property of the HTMLElement interface indicates whether an element's attribute values and the values of its Text node children are to be translated when the page is localized, or whether to leave them unchanged.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/translate)
     */
    translate: boolean;
    /**
     * The **`writingSuggestions`** property of the HTMLElement interface is a string indicating if browser-provided writing suggestions should be enabled under the scope of the element or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/writingSuggestions)
     */
    writingSuggestions: string;
    /**
     * The **`HTMLElement.attachInternals()`** method returns an ElementInternals object. This method allows a custom element to participate in HTML forms. The ElementInternals interface provides utilities for working with these elements in the same way you would work with any standard HTML form element, and also exposes the Accessibility Object Model to the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/attachInternals)
     */
    attachInternals(): ElementInternals;
    /**
     * The **`HTMLElement.click()`** method simulates a mouse click on an element. When called on an element, the element's click event is fired (unless its disabled attribute is set).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/click)
     */
    click(): void;
    /**
     * The **`hidePopover()`** method of the HTMLElement interface hides a popover element (i.e., one that has a valid popover attribute) by removing it from the top layer and styling it with display: none.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/hidePopover)
     */
    hidePopover(): void;
    /**
     * The **`showPopover()`** method of the HTMLElement interface shows a popover element (i.e., one that has a valid popover attribute) by adding it to the top layer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/showPopover)
     */
    showPopover(options?: ShowPopoverOptions): void;
    /**
     * The **`togglePopover()`** method of the HTMLElement interface toggles a popover element (i.e., one that has a valid popover attribute) between the hidden and showing states.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLElement/togglePopover)
     */
    togglePopover(options?: TogglePopoverOptions | boolean): boolean;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLElement: {
    prototype: HTMLElement;
    new(): HTMLElement;
};

/**
 * The **`HTMLEmbedElement`** interface provides special properties (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating <embed> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLEmbedElement)
 */
interface HTMLEmbedElement extends HTMLElement {
    /** @deprecated */
    align: string;
    /**
     * The **`height`** property of the HTMLEmbedElement interface returns a string that reflects the height attribute of the <embed> element, indicating the displayed height of the resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLEmbedElement/height)
     */
    height: string;
    /** @deprecated */
    name: string;
    /**
     * The **`src`** property of the HTMLEmbedElement interface returns a string that indicates the URL of the resource being embedded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLEmbedElement/src)
     */
    src: string;
    /**
     * The **`type`** property of the HTMLEmbedElement interface returns a string that reflects the type attribute of the <embed> element, indicating the MIME type of the resource. It reflects the <embed> element's type attribute
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLEmbedElement/type)
     */
    type: string;
    /**
     * The **`width`** property of the HTMLEmbedElement interface returns a string that reflects the width attribute of the <embed> element, indicating the displayed width of the resource in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLEmbedElement/width)
     */
    width: string;
    /**
     * The **`getSVGDocument()`** method of the HTMLEmbedElement interface returns the Document object of the embedded SVG.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLEmbedElement/getSVGDocument)
     */
    getSVGDocument(): Document | null;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLEmbedElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLEmbedElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLEmbedElement: {
    prototype: HTMLEmbedElement;
    new(): HTMLEmbedElement;
};

/**
 * The **`HTMLFieldSetElement`** interface provides special properties and methods (beyond the regular HTMLElement interface it also has available to it by inheritance) for manipulating the layout and presentation of <fieldset> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement)
 */
interface HTMLFieldSetElement extends HTMLElement {
    /**
     * The **`disabled`** property of the HTMLFieldSetElement interface is a boolean value that reflects the <fieldset> element's disabled attribute, which indicates whether the control is disabled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/disabled)
     */
    disabled: boolean;
    /**
     * The **`elements`** read-only property of the HTMLFieldSetElement interface returns an HTMLCollection object containing all form control elements (<button>, <fieldset>, <input>, <object>, <output>, <select>, and <textarea>) that are descendants of this field set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/elements)
     */
    readonly elements: HTMLCollection;
    /**
     * The **`form`** read-only property of the HTMLFieldSetElement interface returns an HTMLFormElement object that owns this <fieldset>, or null if this fieldset is not owned by any form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/form)
     */
    readonly form: HTMLFormElement | null;
    /**
     * The **`name`** property of the HTMLFieldSetElement interface indicates the name of the <fieldset> element. It reflects the element's name attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/name)
     */
    name: string;
    /**
     * The **`type`** read-only property of the HTMLFieldSetElement interface returns the string "fieldset".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/type)
     */
    readonly type: string;
    /**
     * The **`validationMessage`** read-only property of the HTMLFieldSetElement interface returns a string representing a localized message that describes the validation constraints that the <fieldset> control does not satisfy (if any). This is the empty string as <fieldset> elements are not candidates for constraint validation (HTMLFieldSetElement.willValidate is false).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/validationMessage)
     */
    readonly validationMessage: string;
    /**
     * The **`validity`** read-only property of the HTMLFieldSetElement interface returns a ValidityState object that represents the validity states this element is in. Although <fieldset> elements are never candidates for constraint validation, the validity state may still be invalid if a custom validity message has been set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/validity)
     */
    readonly validity: ValidityState;
    /**
     * The **`willValidate`** read-only property of the HTMLFieldSetElement interface returns false, because <fieldset> elements are not candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/willValidate)
     */
    readonly willValidate: boolean;
    /**
     * The **`checkValidity()`** method of the HTMLFieldSetElement interface checks if the element is valid, but always returns true because <fieldset> elements are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the HTMLFieldSetElement interface performs the same validity checking steps as the checkValidity() method. It always returns true because <fieldset> elements are never candidates for constraint validation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The **`setCustomValidity()`** method of the HTMLFieldSetElement interface sets the custom validity message for the <fieldset> element. Use the empty string to indicate that the element does not have a custom validity error.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFieldSetElement/setCustomValidity)
     */
    setCustomValidity(error: string): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFieldSetElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFieldSetElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var HTMLFieldSetElement: {
    prototype: HTMLFieldSetElement;
    new(): HTMLFieldSetElement;
};

/**
 * Implements the document object model (DOM) representation of the font element. The HTML Font Element <font> defines the font size, font face and color of text.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFontElement)
 */
interface HTMLFontElement extends HTMLElement {
    /**
     * The obsolete **`HTMLFontElement.color`** property is a string that reflects the color HTML attribute, containing either a named color or a color specified in the hexadecimal #RRGGBB format.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFontElement/color)
     */
    color: string;
    /**
     * The obsolete **`HTMLFontElement.face`** property is a string that reflects the face HTML attribute, containing a comma-separated list of one or more font names.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFontElement/face)
     */
    face: string;
    /**
     * The obsolete **`HTMLFontElement.size`** property is a string that reflects the size HTML attribute. It contains either a font size ranging from 1 to 7 or a number relative to the default value 3, for example -2 or +1.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFontElement/size)
     */
    size: string;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFontElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFontElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var HTMLFontElement: {
    prototype: HTMLFontElement;
    new(): HTMLFontElement;
};

/**
 * The **`HTMLFormControlsCollection`** interface represents a collection of HTML form control elements, returned by the HTMLFormElement interface's elements property.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormControlsCollection)
 */
interface HTMLFormControlsCollection extends HTMLCollectionBase {
    /**
     * The **`HTMLFormControlsCollection.namedItem()`** method returns the RadioNodeList or the Element in the collection whose name or id match the specified name, or null if no node matches.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormControlsCollection/namedItem)
     */
    namedItem(name: string): RadioNodeList | Element | null;
}

declare var HTMLFormControlsCollection: {
    prototype: HTMLFormControlsCollection;
    new(): HTMLFormControlsCollection;
};

/**
 * The **`HTMLFormElement`** interface represents a <form> element in the DOM. It allows access to—and, in some cases, modification of—aspects of the form, as well as access to its component elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement)
 */
interface HTMLFormElement extends HTMLElement {
    /**
     * The **`HTMLFormElement.acceptCharset`** property represents the character encoding for the given <form> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/acceptCharset)
     */
    acceptCharset: string;
    /**
     * The **`HTMLFormElement.action`** property represents the action of the <form> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/action)
     */
    action: string;
    /**
     * The **`autocomplete`** property of the HTMLFormElement interface indicates whether the value of the form's controls can be automatically completed by the browser. It reflects the <form> element's autocomplete attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/autocomplete)
     */
    autocomplete: AutoFillBase;
    /**
     * The **`elements`** property of the HTMLFormElement interface returns an HTMLFormControlsCollection listing all the listed form controls associated with the <form> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/elements)
     */
    readonly elements: HTMLFormControlsCollection;
    /**
     * The **`HTMLFormElement.encoding`** property is an alternative name for the enctype element on the DOM HTMLFormElement object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/encoding)
     */
    encoding: string;
    /**
     * The **`HTMLFormElement.enctype`** property is the MIME type of content that is used to submit the form to the server. Possible values are:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/enctype)
     */
    enctype: string;
    /**
     * The **`HTMLFormElement.length`** read-only property returns the number of controls in the <form> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/length)
     */
    readonly length: number;
    /**
     * The **`HTMLFormElement.method`** property represents the HTTP method used to submit the <form>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/method)
     */
    method: string;
    /**
     * The **`HTMLFormElement.name`** property represents the name of the current <form> element as a string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/name)
     */
    name: string;
    /**
     * The **`noValidate`** property of the HTMLFormElement interface is a boolean value indicating if the <form> will bypass constraint validation when submitted. It reflects the <form> element's novalidate attribute; if the attribute present, the value is true.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/noValidate)
     */
    noValidate: boolean;
    /**
     * The **`rel`** property of the HTMLFormElement interface reflects the rel attribute. It is a string containing what kinds of links the HTML <form> element creates, as a space-separated list of enumerated values.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/rel)
     */
    rel: string;
    /**
     * The read-only **`relList`** property of the HTMLFormElement returns a live DOMTokenList object containing the set of link types indicating the relationship between the resource represented by the <form> element and the current document. It reflects the <form> element's rel content attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/relList)
     */
    get relList(): DOMTokenList;
    set relList(value: string);
    /**
     * The **`target`** property of the HTMLFormElement interface represents the target of the form's action (i.e., the frame in which to render its output).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/target)
     */
    target: string;
    /**
     * The **`checkValidity()`** method of the HTMLFormElement interface returns a boolean value which indicates if all associated controls meet any constraint validation rules applied to them. The method also fires an invalid event on each invalid element, but not on the form element itself. Because there's no default browser behavior for checkValidity(), canceling this invalid event has no effect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/checkValidity)
     */
    checkValidity(): boolean;
    /**
     * The **`reportValidity()`** method of the HTMLFormElement interface performs the same validity checking steps as the checkValidity() method. In addition, for each invalid event that was fired and not canceled, the browser displays the problem to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/reportValidity)
     */
    reportValidity(): boolean;
    /**
     * The HTMLFormElement method **`requestSubmit()`** requests that the form be submitted using a specific submit button.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/requestSubmit)
     */
    requestSubmit(submitter?: HTMLElement | null): void;
    /**
     * The **`HTMLFormElement.reset()`** method restores a form element's default values. This method does the same thing as clicking the form's <input type="reset"> control.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/reset)
     */
    reset(): void;
    /**
     * The **`HTMLFormElement.submit()`** method submits a given <form>.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLFormElement/submit)
     */
    submit(): void;
    addEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFormElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof HTMLElementEventMap>(type: K, listener: (this: HTMLFormElement, ev: HTMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
    [index: number]: Element;
    [name: string]: any;
}
