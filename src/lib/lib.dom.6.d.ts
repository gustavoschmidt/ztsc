
/**
 * The **`SVGTextContentElement`** interface is implemented by elements that support rendering child text content. It is inherited by various text-related interfaces, such as SVGTextElement, SVGTSpanElement, and SVGTextPathElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement)
 */
interface SVGTextContentElement extends SVGGraphicsElement {
    /**
     * The **`lengthAdjust`** read-only property of the SVGTextContentElement interface reflects the lengthAdjust attribute of the given element. It takes one of the LENGTHADJUST_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/lengthAdjust)
     */
    readonly lengthAdjust: SVGAnimatedEnumeration;
    /**
     * The **`textLength`** read-only property of the SVGTextContentElement interface reflects the textLength attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/textLength)
     */
    readonly textLength: SVGAnimatedLength;
    /**
     * The **`getCharNumAtPosition()`** method of the SVGTextContentElement interface represents the character which caused a text glyph to be rendered at a given position in the coordinate system. Because the relationship between characters and glyphs is not one-to-one, only the first character of the relevant typographic character is returned.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getCharNumAtPosition)
     */
    getCharNumAtPosition(point?: DOMPointInit): number;
    /**
     * The **`getComputedTextLength()`** method of the SVGTextContentElement interface represents the computed length for the text within the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getComputedTextLength)
     */
    getComputedTextLength(): number;
    /**
     * The **`getEndPositionOfChar()`** method of the SVGTextContentElement interface returns the trailing position of a typographic character after text layout has been performed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getEndPositionOfChar)
     */
    getEndPositionOfChar(charnum: number): DOMPoint;
    /**
     * The **`getExtentOfChar()`** method of the SVGTextContentElement interface the represents computed tight bounding box of the glyph cell that corresponds to a given typographic character.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getExtentOfChar)
     */
    getExtentOfChar(charnum: number): DOMRect;
    /**
     * The **`getNumberOfChars()`** method of the SVGTextContentElement interface represents the total number of addressable characters available for rendering within the current element, regardless of whether they will be rendered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getNumberOfChars)
     */
    getNumberOfChars(): number;
    /**
     * The **`getRotationOfChar()`** method of the SVGTextContentElement interface the represents the rotation of a typographic character.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getRotationOfChar)
     */
    getRotationOfChar(charnum: number): number;
    /**
     * The **`getStartPositionOfChar()`** method of the SVGTextContentElement interface returns the position of a typographic character after text layout has been performed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getStartPositionOfChar)
     */
    getStartPositionOfChar(charnum: number): DOMPoint;
    /**
     * The **`getSubStringLength()`** method of the SVGTextContentElement interface represents the computed length of the formatted text advance distance for a substring of text within the element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextContentElement/getSubStringLength)
     */
    getSubStringLength(charnum: number, nchars: number): number;
    /** @deprecated */
    selectSubString(charnum: number, nchars: number): void;
    readonly LENGTHADJUST_UNKNOWN: 0;
    readonly LENGTHADJUST_SPACING: 1;
    readonly LENGTHADJUST_SPACINGANDGLYPHS: 2;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextContentElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextContentElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGTextContentElement: {
    prototype: SVGTextContentElement;
    new(): SVGTextContentElement;
    readonly LENGTHADJUST_UNKNOWN: 0;
    readonly LENGTHADJUST_SPACING: 1;
    readonly LENGTHADJUST_SPACINGANDGLYPHS: 2;
};

/**
 * The **`SVGTextElement`** interface corresponds to the <text> elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextElement)
 */
interface SVGTextElement extends SVGTextPositioningElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGTextElement: {
    prototype: SVGTextElement;
    new(): SVGTextElement;
};

/**
 * The **`SVGTextPathElement`** interface corresponds to the <textPath> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPathElement)
 */
interface SVGTextPathElement extends SVGTextContentElement, SVGURIReference {
    /**
     * The **`method`** read-only property of the SVGTextPathElement interface reflects the method attribute of the given <textPath> element. It takes one of the TEXTPATH_METHODTYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPathElement/method)
     */
    readonly method: SVGAnimatedEnumeration;
    /**
     * The **`spacing`** read-only property of the SVGTextPathElement interface reflects the spacing attribute of the given <textPath> element. It takes one of the TEXTPATH_SPACINGTYPE_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPathElement/spacing)
     */
    readonly spacing: SVGAnimatedEnumeration;
    /**
     * The **`startOffset`** read-only property of the SVGTextPathElement interface reflects the X component of the startOffset attribute of the given <textPath>, which defines an offset from the start of the path for the initial current text position along the path after converting the path to the <textPath> element's coordinate system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPathElement/startOffset)
     */
    readonly startOffset: SVGAnimatedLength;
    readonly TEXTPATH_METHODTYPE_UNKNOWN: 0;
    readonly TEXTPATH_METHODTYPE_ALIGN: 1;
    readonly TEXTPATH_METHODTYPE_STRETCH: 2;
    readonly TEXTPATH_SPACINGTYPE_UNKNOWN: 0;
    readonly TEXTPATH_SPACINGTYPE_AUTO: 1;
    readonly TEXTPATH_SPACINGTYPE_EXACT: 2;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextPathElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGTextPathElement: {
    prototype: SVGTextPathElement;
    new(): SVGTextPathElement;
    readonly TEXTPATH_METHODTYPE_UNKNOWN: 0;
    readonly TEXTPATH_METHODTYPE_ALIGN: 1;
    readonly TEXTPATH_METHODTYPE_STRETCH: 2;
    readonly TEXTPATH_SPACINGTYPE_UNKNOWN: 0;
    readonly TEXTPATH_SPACINGTYPE_AUTO: 1;
    readonly TEXTPATH_SPACINGTYPE_EXACT: 2;
};

/**
 * The **`SVGTextPositioningElement`** interface is implemented by elements that support attributes that position individual text glyphs. It is inherited by SVGTextElement and SVGTSpanElement.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPositioningElement)
 */
interface SVGTextPositioningElement extends SVGTextContentElement {
    /**
     * The **`dx`** read-only property of the SVGTextPositioningElement interface describes the x-axis coordinate of the SVGTextElement or SVGTSpanElement as an SVGAnimatedLengthList. It reflects the dx attribute's horizontal displacement of the individual text glyphs in the user coordinate system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPositioningElement/dx)
     */
    readonly dx: SVGAnimatedLengthList;
    /**
     * The **`dy`** read-only property of the SVGTextPositioningElement interface describes the y-axis coordinate of the SVGTextElement or SVGTSpanElement as an SVGAnimatedLengthList. It reflects the dy attribute's vertical displacement of the individual text glyphs in the user coordinate system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPositioningElement/dy)
     */
    readonly dy: SVGAnimatedLengthList;
    /**
     * The **`rotate`** read-only property of the SVGTextPositioningElement interface reflects the rotation of individual text glyphs, as specified by the rotate attribute of the given element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPositioningElement/rotate)
     */
    readonly rotate: SVGAnimatedNumberList;
    /**
     * The **`x`** read-only property of the SVGTextPositioningElement interface describes the x-axis coordinate of the SVGTextElement or SVGTSpanElement as an SVGAnimatedLengthList. It reflects the x attribute's horizontal position of the individual text glyphs in the user coordinate system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPositioningElement/x)
     */
    readonly x: SVGAnimatedLengthList;
    /**
     * The **`y`** read-only property of the SVGTextPositioningElement interface describes the y-axis coordinate of the SVGTextElement or SVGTSpanElement as an SVGAnimatedLengthList. It reflects the y attribute's vertical position of the individual text glyphs in the user coordinate system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTextPositioningElement/y)
     */
    readonly y: SVGAnimatedLengthList;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextPositioningElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTextPositioningElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGTextPositioningElement: {
    prototype: SVGTextPositioningElement;
    new(): SVGTextPositioningElement;
};

/**
 * The **`SVGTitleElement`** interface corresponds to the <title> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTitleElement)
 */
interface SVGTitleElement extends SVGElement {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTitleElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGTitleElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGTitleElement: {
    prototype: SVGTitleElement;
    new(): SVGTitleElement;
};

/**
 * The **`SVGTransform`** interface reflects one of the component transformations within an SVGTransformList; thus, an SVGTransform object corresponds to a single component (e.g., scale(…) or matrix(…)) within a transform attribute.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform)
 */
interface SVGTransform {
    /**
     * The **`angle`** read-only property of the SVGTransform interface represents the angle of the transformation in degrees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/angle)
     */
    readonly angle: number;
    /**
     * The **`matrix`** read-only property of the SVGTransform interface represents the transformation matrix that corresponds to the transformation type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/matrix)
     */
    readonly matrix: DOMMatrix;
    /**
     * The **`type`** read-only property of the SVGTransform interface represents the type of transformation applied, specified by one of the SVG_TRANSFORM_* constants defined on this interface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/type)
     */
    readonly type: number;
    /**
     * The **`setMatrix()`** method of the SVGTransform interface sets the transform type to SVG_TRANSFORM_MATRIX, with parameter matrix defining the new transformation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/setMatrix)
     */
    setMatrix(matrix?: DOMMatrix2DInit): void;
    /**
     * The **`setRotate()`** method of the SVGTransform interface sets the transform type to SVG_TRANSFORM_ROTATE, with parameter angle defining the rotation angle and parameters cx and cy defining the optional center of rotation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/setRotate)
     */
    setRotate(angle: number, cx: number, cy: number): void;
    /**
     * The **`setScale()`** method of the SVGTransform interface sets the transform type to SVG_TRANSFORM_SCALE, with parameters sx and sy defining the scale amounts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/setScale)
     */
    setScale(sx: number, sy: number): void;
    /**
     * The **`setSkewX()`** method of the SVGTransform interface sets the transform type to SVG_TRANSFORM_SKEWX, with parameter angle defining the amount of skew along the X-axis.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/setSkewX)
     */
    setSkewX(angle: number): void;
    /**
     * The **`setSkewY()`** method of the SVGTransform interface sets the transform type to SVG_TRANSFORM_SKEWY, with parameter angle defining the amount of skew along the Y-axis.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/setSkewY)
     */
    setSkewY(angle: number): void;
    /**
     * The **`setTranslate()`** method of the SVGTransform interface sets the transform type to SVG_TRANSFORM_TRANSLATE, with parameters tx and ty defining the translation amounts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransform/setTranslate)
     */
    setTranslate(tx: number, ty: number): void;
    readonly SVG_TRANSFORM_UNKNOWN: 0;
    readonly SVG_TRANSFORM_MATRIX: 1;
    readonly SVG_TRANSFORM_TRANSLATE: 2;
    readonly SVG_TRANSFORM_SCALE: 3;
    readonly SVG_TRANSFORM_ROTATE: 4;
    readonly SVG_TRANSFORM_SKEWX: 5;
    readonly SVG_TRANSFORM_SKEWY: 6;
}

declare var SVGTransform: {
    prototype: SVGTransform;
    new(): SVGTransform;
    readonly SVG_TRANSFORM_UNKNOWN: 0;
    readonly SVG_TRANSFORM_MATRIX: 1;
    readonly SVG_TRANSFORM_TRANSLATE: 2;
    readonly SVG_TRANSFORM_SCALE: 3;
    readonly SVG_TRANSFORM_ROTATE: 4;
    readonly SVG_TRANSFORM_SKEWX: 5;
    readonly SVG_TRANSFORM_SKEWY: 6;
};

/**
 * The **`SVGTransformList`** interface defines a list of SVGTransform objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList)
 */
interface SVGTransformList {
    /**
     * The **`length`** read-only property of the SVGTransformList interface represents the number of items in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/length)
     */
    readonly length: number;
    /**
     * The **`numberOfItems`** read-only property of the SVGTransformList interface represents the number of items in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/numberOfItems)
     */
    readonly numberOfItems: number;
    /**
     * The **`appendItem()`** method of the SVGTransformList interface inserts a new item at the end of the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/appendItem)
     */
    appendItem(newItem: SVGTransform): SVGTransform;
    /**
     * The **`clear()`** method of the SVGTransformList interface clears all existing current items from the list, with the result being an empty list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/clear)
     */
    clear(): void;
    /**
     * The **`consolidate()`** method of the SVGTransformList interface consolidates the list of separate SVGTransform objects by multiplying the equivalent transformation matrices together to result in a list consisting of a single SVGTransform object of type SVG_TRANSFORM_MATRIX.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/consolidate)
     */
    consolidate(): SVGTransform | null;
    /**
     * The **`createSVGTransformFromMatrix()`** method of the SVGTransformList interface creates an SVGTransform object which is initialized to a transform of type SVG_TRANSFORM_MATRIX and whose values are the given matrix.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/createSVGTransformFromMatrix)
     */
    createSVGTransformFromMatrix(matrix?: DOMMatrix2DInit): SVGTransform;
    /**
     * The **`getItem()`** method of the SVGTransformList interface returns the specified item from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/getItem)
     */
    getItem(index: number): SVGTransform;
    /**
     * The **`initialize()`** method of the SVGTransformList interface clears all existing current items from the list and re-initializes the list to hold the single item specified by the parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/initialize)
     */
    initialize(newItem: SVGTransform): SVGTransform;
    /**
     * The **`insertItemBefore()`** method of the SVGTransformList interface inserts a new item into the list at the specified position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/insertItemBefore)
     */
    insertItemBefore(newItem: SVGTransform, index: number): SVGTransform;
    /**
     * The **`removeItem()`** method of the SVGTransformList interface removes an existing item from the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/removeItem)
     */
    removeItem(index: number): SVGTransform;
    /**
     * The **`replaceItem()`** method of the SVGTransformList interface replaces an existing item in the list with a new item.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGTransformList/replaceItem)
     */
    replaceItem(newItem: SVGTransform, index: number): SVGTransform;
    [index: number]: SVGTransform;
}

declare var SVGTransformList: {
    prototype: SVGTransformList;
    new(): SVGTransformList;
};

interface SVGURIReference {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGAElement/href) */
    readonly href: SVGAnimatedString;
}

/**
 * The **`SVGUnitTypes`** interface defines a commonly used set of constants used for reflecting gradientUnits, patternContentUnits and other similar attributes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGUnitTypes)
 */
interface SVGUnitTypes {
    readonly SVG_UNIT_TYPE_UNKNOWN: 0;
    readonly SVG_UNIT_TYPE_USERSPACEONUSE: 1;
    readonly SVG_UNIT_TYPE_OBJECTBOUNDINGBOX: 2;
}

declare var SVGUnitTypes: {
    prototype: SVGUnitTypes;
    new(): SVGUnitTypes;
    readonly SVG_UNIT_TYPE_UNKNOWN: 0;
    readonly SVG_UNIT_TYPE_USERSPACEONUSE: 1;
    readonly SVG_UNIT_TYPE_OBJECTBOUNDINGBOX: 2;
};

/**
 * The **`SVGUseElement`** interface corresponds to the <use> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGUseElement)
 */
interface SVGUseElement extends SVGGraphicsElement, SVGURIReference {
    /**
     * The **`height`** read-only property of the SVGUseElement interface describes the height of the referenced element as an SVGAnimatedLength. It reflects the computed value of the height attribute on the <use> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGUseElement/height)
     */
    readonly height: SVGAnimatedLength;
    /**
     * The **`width`** read-only property of the SVGUseElement interface describes the width of the referenced element as an SVGAnimatedLength. It reflects the computed value of the width attribute on the <use> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGUseElement/width)
     */
    readonly width: SVGAnimatedLength;
    /**
     * The **`x`** read-only property of the SVGUseElement interface describes the x-axis coordinate of the start point of the referenced element as an SVGAnimatedLength. It reflects the computed value of the x attribute on the <use> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGUseElement/x)
     */
    readonly x: SVGAnimatedLength;
    /**
     * The **`y`** read-only property of the SVGUseElement interface describes the y-axis coordinate of the start point of the referenced element as an SVGAnimatedLength. It reflects the computed value of the y attribute on the <use> element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGUseElement/y)
     */
    readonly y: SVGAnimatedLength;
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGUseElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGUseElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGUseElement: {
    prototype: SVGUseElement;
    new(): SVGUseElement;
};

/**
 * The **`SVGViewElement`** interface provides access to the properties of <view> elements, as well as methods to manipulate them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SVGViewElement)
 */
interface SVGViewElement extends SVGElement, SVGFitToViewBox {
    addEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGViewElement, ev: SVGElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SVGElementEventMap>(type: K, listener: (this: SVGViewElement, ev: SVGElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SVGViewElement: {
    prototype: SVGViewElement;
    new(): SVGViewElement;
};

/** The **`Sanitizer`** interface of the HTML Sanitizer API defines a configuration object that specifies what elements, attributes and comments are allowed or should be removed when inserting strings of HTML into an Element or ShadowRoot, or when parsing an HTML string into a Document. */
interface Sanitizer {
    /**
     * The **`allowAttribute()`** method of the Sanitizer interface sets an attribute to be allowed on all elements when the sanitizer is used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/allowAttribute)
     */
    allowAttribute(attribute: SanitizerAttribute): boolean;
    /**
     * The **`allowElement()`** method of the Sanitizer interface sets that the specified element is allowed in the output when the sanitizer is used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/allowElement)
     */
    allowElement(element: SanitizerElementWithAttributes): boolean;
    /**
     * The **`get()`** method of the Sanitizer interface returns a SanitizerConfig dictionary instance that represents the current Sanitizer configuration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/get)
     */
    get(): SanitizerConfig;
    /**
     * The **`removeAttribute()`** method of the Sanitizer interface sets an attribute to be removed from all elements when the sanitizer is used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/removeAttribute)
     */
    removeAttribute(attribute: SanitizerAttribute): boolean;
    /**
     * The **`removeElement()`** method of the Sanitizer interface sets the specified element be removed from the output when the sanitizer is used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/removeElement)
     */
    removeElement(element: SanitizerElement): boolean;
    /**
     * The **`removeUnsafe()`** method of the Sanitizer interface configures the sanitizer configuration so that it will remove all elements, attributes, and event handler content attributes that are considered XSS-unsafe by the browser.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/removeUnsafe)
     */
    removeUnsafe(): boolean;
    /**
     * The **`replaceElementWithChildren()`** method of the Sanitizer interface sets an element to be replaced by its child HTML elements when the sanitizer is used. This is primarily used for stripping styles from text.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/replaceElementWithChildren)
     */
    replaceElementWithChildren(element: SanitizerElement): boolean;
    /**
     * The **`setComments()`** method of the Sanitizer interface sets whether comments will be allowed or removed by the sanitizer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/setComments)
     */
    setComments(allow: boolean): boolean;
    /**
     * The **`setDataAttributes()`** method of the Sanitizer interface sets whether all data-* attributes will be allowed by the sanitizer, or if they must be individually specified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Sanitizer/setDataAttributes)
     */
    setDataAttributes(allow: boolean): boolean;
}

declare var Sanitizer: {
    prototype: Sanitizer;
    new(configuration?: SanitizerConfig | SanitizerPresets): Sanitizer;
};

/**
 * The **`Scheduler`** interface of the Prioritized Task Scheduling API provides methods for scheduling prioritized tasks.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Scheduler)
 */
interface Scheduler {
    /**
     * The **`postTask()`** method of the Scheduler interface is used for adding tasks to be scheduled according to their priority.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Scheduler/postTask)
     */
    postTask(callback: SchedulerPostTaskCallback, options?: SchedulerPostTaskOptions): Promise<any>;
    /**
     * The **`yield()`** method of the Scheduler interface is used for yielding to the main thread during a task and continuing execution later, with the continuation scheduled as a prioritized task (see the Prioritized Task Scheduling API for more information). This allows long-running work to be broken up so the browser stays responsive.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Scheduler/yield)
     */
    yield(): Promise<void>;
}

declare var Scheduler: {
    prototype: Scheduler;
    new(): Scheduler;
};

/**
 * The **`Screen`** interface represents a screen, usually the one on which the current window is being rendered, and is obtained using window.screen.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen)
 */
interface Screen {
    /**
     * The read-only Screen interface's **`availHeight`** property returns the height, in CSS pixels, of the space available for Web content on the screen. Since Screen is exposed on the Window interface's window.screen property, you access availHeight using window.screen.availHeight.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/availHeight)
     */
    readonly availHeight: number;
    /**
     * The **`Screen.availWidth`** property returns the amount of horizontal space (in CSS pixels) available to the window.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/availWidth)
     */
    readonly availWidth: number;
    /**
     * The **`Screen.colorDepth`** read-only property returns the color depth of the screen. Per the CSSOM, some implementations return 24 for compatibility reasons. See the browser compatibility section for those that don't.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/colorDepth)
     */
    readonly colorDepth: number;
    /**
     * The **`Screen.height`** read-only property returns the height of the screen in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/height)
     */
    readonly height: number;
    /**
     * The **`orientation`** read-only property of the Screen interface returns the current orientation of the screen.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/orientation)
     */
    readonly orientation: ScreenOrientation;
    /**
     * Returns the bit depth of the screen. Per the CSSOM, some implementations return 24 for compatibility reasons. See the browser compatibility section for those that don't.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/pixelDepth)
     */
    readonly pixelDepth: number;
    /**
     * The **`Screen.width`** read-only property returns the width of the screen in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Screen/width)
     */
    readonly width: number;
}

declare var Screen: {
    prototype: Screen;
    new(): Screen;
};

interface ScreenOrientationEventMap {
    "change": Event;
}

/**
 * The **`ScreenOrientation`** interface of the Screen Orientation API provides information about the current orientation of the document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScreenOrientation)
 */
interface ScreenOrientation extends EventTarget {
    /**
     * The **`angle`** read-only property of the ScreenOrientation interface returns the document's current orientation angle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScreenOrientation/angle)
     */
    readonly angle: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScreenOrientation/change_event) */
    onchange: ((this: ScreenOrientation, ev: Event) => any) | null;
    /**
     * The **`type`** read-only property of the ScreenOrientation interface returns the document's current orientation type, one of portrait-primary, portrait-secondary, landscape-primary, or landscape-secondary.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScreenOrientation/type)
     */
    readonly type: OrientationType;
    /**
     * The **`lock()`** method of the ScreenOrientation interface locks the orientation of the containing document to the specified orientation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScreenOrientation/lock)
     */
    lock(orientation: OrientationLockType): Promise<void>;
    /**
     * The **`unlock()`** method of the ScreenOrientation interface unlocks the orientation of the containing document, effectively locking it to the default screen orientation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScreenOrientation/unlock)
     */
    unlock(): void;
    addEventListener<K extends keyof ScreenOrientationEventMap>(type: K, listener: (this: ScreenOrientation, ev: ScreenOrientationEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ScreenOrientationEventMap>(type: K, listener: (this: ScreenOrientation, ev: ScreenOrientationEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var ScreenOrientation: {
    prototype: ScreenOrientation;
    new(): ScreenOrientation;
};

interface ScriptProcessorNodeEventMap {
    "audioprocess": AudioProcessingEvent;
}

/**
 * The **`ScriptProcessorNode`** interface allows the generation, processing, or analyzing of audio using JavaScript.
 * @deprecated As of the August 29 2014 Web Audio API spec publication, this feature has been marked as deprecated, and was replaced by AudioWorklet (see AudioWorkletNode).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScriptProcessorNode)
 */
interface ScriptProcessorNode extends AudioNode {
    /**
     * The **`bufferSize`** property of the ScriptProcessorNode interface returns an integer representing both the input and output buffer size, in sample-frames. Its value can be a power of 2 value in the range 256 – 16384.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScriptProcessorNode/bufferSize)
     */
    readonly bufferSize: number;
    /**
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScriptProcessorNode/audioprocess_event)
     */
    onaudioprocess: ((this: ScriptProcessorNode, ev: AudioProcessingEvent) => any) | null;
    addEventListener<K extends keyof ScriptProcessorNodeEventMap>(type: K, listener: (this: ScriptProcessorNode, ev: ScriptProcessorNodeEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ScriptProcessorNodeEventMap>(type: K, listener: (this: ScriptProcessorNode, ev: ScriptProcessorNodeEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

/** @deprecated */
declare var ScriptProcessorNode: {
    prototype: ScriptProcessorNode;
    new(): ScriptProcessorNode;
};

/**
 * The **`ScrollTimeline`** interface of the Web Animations API represents a scroll progress timeline (see CSS scroll-driven animations for more details).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScrollTimeline)
 */
interface ScrollTimeline extends AnimationTimeline {
    /**
     * The **`axis`** read-only property of the ScrollTimeline interface returns an enumerated value representing the scroll axis that is driving the progress of the timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScrollTimeline/axis)
     */
    readonly axis: ScrollAxis;
    /**
     * The **`source`** read-only property of the ScrollTimeline interface returns a reference to the scrollable element (scroller) whose scroll position is driving the progress of the timeline and therefore the animation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ScrollTimeline/source)
     */
    readonly source: Element | null;
}

declare var ScrollTimeline: {
    prototype: ScrollTimeline;
    new(options?: ScrollTimelineOptions): ScrollTimeline;
};

/**
 * The **`SecurityPolicyViolationEvent`** interface inherits from Event, and represents the event object of a securitypolicyviolation event sent on an Element, Document, or worker when its Content Security Policy (CSP) is violated.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent)
 */
interface SecurityPolicyViolationEvent extends Event {
    /**
     * The **`blockedURI`** read-only property of the SecurityPolicyViolationEvent interface is a string representing the URI of the resource that was blocked because it violates a Content Security Policy (CSP).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/blockedURI)
     */
    readonly blockedURI: string;
    /**
     * The **`columnNumber`** read-only property of the SecurityPolicyViolationEvent interface is the column number in the document or worker script at which the Content Security Policy (CSP) violation occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/columnNumber)
     */
    readonly columnNumber: number;
    /**
     * The **`disposition`** read-only property of the SecurityPolicyViolationEvent interface indicates how the violated Content Security Policy (CSP) is configured to be treated by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/disposition)
     */
    readonly disposition: SecurityPolicyViolationEventDisposition;
    /**
     * The **`documentURI`** read-only property of the SecurityPolicyViolationEvent interface is a string representing the URI of the document or worker in which the Content Security Policy (CSP) violation occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/documentURI)
     */
    readonly documentURI: string;
    /**
     * The **`effectiveDirective`** read-only property of the SecurityPolicyViolationEvent interface is a string representing the Content Security Policy (CSP) directive that was violated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/effectiveDirective)
     */
    readonly effectiveDirective: string;
    /**
     * The **`lineNumber`** read-only property of the SecurityPolicyViolationEvent interface is the line number in the document or worker script at which the Content Security Policy (CSP) violation occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/lineNumber)
     */
    readonly lineNumber: number;
    /**
     * The **`originalPolicy`** read-only property of the SecurityPolicyViolationEvent interface is a string containing the Content Security Policy (CSP) whose enforcement uncovered the violation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/originalPolicy)
     */
    readonly originalPolicy: string;
    /**
     * The **`referrer`** read-only property of the SecurityPolicyViolationEvent interface is a string representing the referrer for the resources whose Content Security Policy (CSP) was violated. This will be a URL or null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/referrer)
     */
    readonly referrer: string;
    /**
     * The **`sample`** read-only property of the SecurityPolicyViolationEvent interface is a string representing a sample of the resource that caused the Content Security Policy (CSP) violation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/sample)
     */
    readonly sample: string;
    /**
     * The **`sourceFile`** read-only property of the SecurityPolicyViolationEvent interface is a string representing the URL of the script in which the Content Security Policy (CSP) violation occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/sourceFile)
     */
    readonly sourceFile: string;
    /**
     * The **`statusCode`** read-only property of the SecurityPolicyViolationEvent interface is a number representing the HTTP status code of the window or worker in which the Content Security Policy (CSP) violation occurred.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/statusCode)
     */
    readonly statusCode: number;
    /**
     * The **`violatedDirective`** read-only property of the SecurityPolicyViolationEvent interface is a string representing the Content Security Policy (CSP) directive that was violated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SecurityPolicyViolationEvent/violatedDirective)
     */
    readonly violatedDirective: string;
}

declare var SecurityPolicyViolationEvent: {
    prototype: SecurityPolicyViolationEvent;
    new(type: string, eventInitDict?: SecurityPolicyViolationEventInit): SecurityPolicyViolationEvent;
};

/**
 * A **`Selection`** object represents the range of text selected by the user or the current position of the caret. Each document is associated with a unique selection object, which can be retrieved by document.getSelection() or window.getSelection() and then be examined and modified.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection)
 */
interface Selection {
    /**
     * The **`Selection.anchorNode`** read-only property returns the Node in which the selection begins. It can return null if selection never existed in the document (e.g., an iframe that was never clicked on, or the node belongs to another document tree).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/anchorNode)
     */
    readonly anchorNode: Node | null;
    /**
     * The **`Selection.anchorOffset`** read-only property returns the number of characters that the selection's anchor is offset within the Selection.anchorNode if said node is of type Text, CDATASection or Comment.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/anchorOffset)
     */
    readonly anchorOffset: number;
    /**
     * The **`direction`** read-only property of the Selection interface is a string that provides the direction of the current selection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/direction)
     */
    readonly direction: string;
    /**
     * The **`Selection.focusNode`** read-only property returns the Node in which the selection ends. It can return null if selection never existed in the document (e.g., an iframe that was never clicked on, or the node belongs to another document tree).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/focusNode)
     */
    readonly focusNode: Node | null;
    /**
     * The **`Selection.focusOffset`** read-only property returns the number of characters that the selection's focus is offset within the Selection.focusNode if said node is of type Text, CDATASection or Comment.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/focusOffset)
     */
    readonly focusOffset: number;
    /**
     * The **`Selection.isCollapsed`** read-only property returns a boolean value which indicates whether or not there is currently any text selected. No text is selected when the selection's start and end points are at the same position in the content.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/isCollapsed)
     */
    readonly isCollapsed: boolean;
    /**
     * The **`Selection.rangeCount`** read-only property returns the number of ranges in the selection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/rangeCount)
     */
    readonly rangeCount: number;
    /**
     * The **`type`** read-only property of the Selection interface returns a string describing the type of the current selection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/type)
     */
    readonly type: string;
    /**
     * The **`Selection.addRange()`** method adds a Range to a Selection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/addRange)
     */
    addRange(range: Range): void;
    /**
     * The **`Selection.collapse()`** method collapses the current selection to a single point. The document is not modified. If the content is focused and editable, the caret will blink there.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/collapse)
     */
    collapse(node: Node | null, offset?: number): void;
    /**
     * The **`Selection.collapseToEnd()`** method collapses the selection to the end of the last range in the selection. If the content of the selection is focused and editable, the caret will blink there.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/collapseToEnd)
     */
    collapseToEnd(): void;
    /**
     * The **`Selection.collapseToStart()`** method collapses the selection to the start of the first range in the selection. If the content of the selection is focused and editable, the caret will blink there.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/collapseToStart)
     */
    collapseToStart(): void;
    /**
     * The **`Selection.containsNode()`** method indicates whether a specified node is part of the selection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/containsNode)
     */
    containsNode(node: Node, allowPartialContainment?: boolean): boolean;
    /**
     * The **`deleteFromDocument()`** method of the Selection interface invokes the Range.deleteContents() method on the selected Range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/deleteFromDocument)
     */
    deleteFromDocument(): void;
    /**
     * The **`Selection.empty()`** method removes all ranges from the selection, leaving the anchorNode and focusNode properties equal to null and nothing selected. When this method is called, a selectionchange event is fired at the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/empty)
     */
    empty(): void;
    /**
     * The **`Selection.extend()`** method moves the focus of the selection to a specified point. The anchor of the selection does not move. The selection will be from the anchor to the new focus, regardless of direction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/extend)
     */
    extend(node: Node, offset?: number): void;
    /**
     * The **`Selection.getComposedRanges()`** method returns an array of StaticRange objects representing the current selection ranges, and can return ranges that potentially cross shadow boundaries.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/getComposedRanges)
     */
    getComposedRanges(options?: GetComposedRangesOptions): StaticRange[];
    /**
     * The **`getRangeAt()`** method of the Selection interface returns a range object representing a currently selected range.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/getRangeAt)
     */
    getRangeAt(index: number): Range;
    /**
     * The **`Selection.modify()`** method applies a change to the current selection or cursor position, using simple textual commands.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/modify)
     */
    modify(alter?: string, direction?: string, granularity?: string): void;
    /**
     * The **`Selection.removeAllRanges()`** method removes all ranges from the selection, leaving the anchorNode and focusNode properties equal to null and nothing selected. When this method is called, a selectionchange event is fired at the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/removeAllRanges)
     */
    removeAllRanges(): void;
    /**
     * The **`Selection.removeRange()`** method removes a range from a selection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/removeRange)
     */
    removeRange(range: Range): void;
    /**
     * The **`Selection.selectAllChildren()`** method adds all the children of the specified node to the selection. Previous selection is lost.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/selectAllChildren)
     */
    selectAllChildren(node: Node): void;
    /**
     * The **`setBaseAndExtent()`** method of the Selection interface sets the selection to be a range including all or parts of two specified DOM nodes, and any content located between them.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/setBaseAndExtent)
     */
    setBaseAndExtent(anchorNode: Node, anchorOffset: number, focusNode: Node, focusOffset: number): void;
    /**
     * The **`Selection.setPosition()`** method collapses the current selection to a single point. The document is not modified. If the content is focused and editable, the caret will blink there.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Selection/setPosition)
     */
    setPosition(node: Node | null, offset?: number): void;
    toString(): string;
}

declare var Selection: {
    prototype: Selection;
    new(): Selection;
};

interface ServiceWorkerEventMap extends AbstractWorkerEventMap {
    "statechange": Event;
}

/**
 * The **`ServiceWorker`** interface of the Service Worker API provides a reference to a service worker. Multiple browsing contexts (e.g., pages, workers, etc.) can be associated with the same service worker, each through a unique ServiceWorker object.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorker)
 */
interface ServiceWorker extends EventTarget, AbstractWorker {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorker/statechange_event) */
    onstatechange: ((this: ServiceWorker, ev: Event) => any) | null;
    /**
     * Returns the ServiceWorker serialized script URL defined as part of ServiceWorkerRegistration. Must be on the same origin as the document that registers the ServiceWorker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorker/scriptURL)
     */
    readonly scriptURL: string;
    /**
     * The **`state`** read-only property of the ServiceWorker interface returns a string representing the current state of the service worker. It can be one of the following values: parsed, installing, installed, activating, activated, or redundant.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorker/state)
     */
    readonly state: ServiceWorkerState;
    /**
     * The **`postMessage()`** method of the ServiceWorker interface sends a message to the worker. The first parameter is the data to send to the worker. The data may be any JavaScript object which can be handled by the structured clone algorithm.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorker/postMessage)
     */
    postMessage(message: any, transfer: Transferable[]): void;
    postMessage(message: any, options?: StructuredSerializeOptions): void;
    addEventListener<K extends keyof ServiceWorkerEventMap>(type: K, listener: (this: ServiceWorker, ev: ServiceWorkerEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ServiceWorkerEventMap>(type: K, listener: (this: ServiceWorker, ev: ServiceWorkerEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var ServiceWorker: {
    prototype: ServiceWorker;
    new(): ServiceWorker;
};

interface ServiceWorkerContainerEventMap {
    "controllerchange": Event;
    "message": MessageEvent;
    "messageerror": MessageEvent;
}

/**
 * The **`ServiceWorkerContainer`** interface of the Service Worker API provides an object representing the service worker as an overall unit in the network ecosystem, including facilities to register, unregister and update service workers, and access the state of service workers and their registrations.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer)
 */
interface ServiceWorkerContainer extends EventTarget {
    /**
     * The **`controller`** read-only property of the ServiceWorkerContainer interface represents the active service worker controlling the current page (associated with this ServiceWorkerContainer), or null if the page has no active or activating service worker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/controller)
     */
    readonly controller: ServiceWorker | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/controllerchange_event) */
    oncontrollerchange: ((this: ServiceWorkerContainer, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/message_event) */
    onmessage: ((this: ServiceWorkerContainer, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/messageerror_event) */
    onmessageerror: ((this: ServiceWorkerContainer, ev: MessageEvent) => any) | null;
    /**
     * The **`ready`** read-only property of the ServiceWorkerContainer interface provides a way of delaying code execution until a service worker is active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/ready)
     */
    readonly ready: Promise<ServiceWorkerRegistration>;
    /**
     * The **`getRegistration()`** method of the ServiceWorkerContainer interface gets a ServiceWorkerRegistration object whose scope URL matches the provided client URL. The method returns a Promise that resolves to a ServiceWorkerRegistration or undefined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/getRegistration)
     */
    getRegistration(clientURL?: string | URL): Promise<ServiceWorkerRegistration | undefined>;
    /**
     * The **`getRegistrations()`** method of the ServiceWorkerContainer interface gets all ServiceWorkerRegistrations associated with a ServiceWorkerContainer, in an array. The method returns a Promise that resolves to an array of ServiceWorkerRegistration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/getRegistrations)
     */
    getRegistrations(): Promise<ReadonlyArray<ServiceWorkerRegistration>>;
    /**
     * The **`register()`** method of the ServiceWorkerContainer interface creates or updates a ServiceWorkerRegistration for the given scope.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/register)
     */
    register(scriptURL: string | URL, options?: RegistrationOptions): Promise<ServiceWorkerRegistration>;
    /**
     * The **`startMessages()`** method of the ServiceWorkerContainer interface explicitly starts the flow of messages being dispatched from a service worker to pages under its control (e.g., sent via Client.postMessage()). This can be used to react to sent messages earlier, even before that page's content has finished loading.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerContainer/startMessages)
     */
    startMessages(): void;
    addEventListener<K extends keyof ServiceWorkerContainerEventMap>(type: K, listener: (this: ServiceWorkerContainer, ev: ServiceWorkerContainerEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ServiceWorkerContainerEventMap>(type: K, listener: (this: ServiceWorkerContainer, ev: ServiceWorkerContainerEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var ServiceWorkerContainer: {
    prototype: ServiceWorkerContainer;
    new(): ServiceWorkerContainer;
};

interface ServiceWorkerRegistrationEventMap {
    "updatefound": Event;
}

/**
 * The **`ServiceWorkerRegistration`** interface of the Service Worker API represents the service worker registration. You register a service worker to control one or more pages that share the same origin.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration)
 */
interface ServiceWorkerRegistration extends EventTarget, PushManagerAttribute {
    /**
     * The **`active`** read-only property of the ServiceWorkerRegistration interface returns a service worker whose ServiceWorker.state is activating or activated. This property is initially set to null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/active)
     */
    readonly active: ServiceWorker | null;
    /**
     * The **`cookies`** read-only property of the ServiceWorkerRegistration interface returns a reference to the CookieStoreManager interface, which enables a web app to subscribe to and unsubscribe from cookie change events in a service worker. This is an entry point for the Cookie Store API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/cookies)
     */
    readonly cookies: CookieStoreManager;
    /**
     * The **`installing`** read-only property of the ServiceWorkerRegistration interface returns a service worker whose ServiceWorker.state is installing. This property is initially set to null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/installing)
     */
    readonly installing: ServiceWorker | null;
    /**
     * The **`navigationPreload`** read-only property of the ServiceWorkerRegistration interface returns the NavigationPreloadManager associated with the current service worker registration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/navigationPreload)
     */
    readonly navigationPreload: NavigationPreloadManager;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/updatefound_event) */
    onupdatefound: ((this: ServiceWorkerRegistration, ev: Event) => any) | null;
    /**
     * The **`scope`** read-only property of the ServiceWorkerRegistration interface returns a string representing a URL that defines a service worker's registration scope; that is, the range of URLs a service worker can control. This is set using the scope parameter specified in the call to ServiceWorkerContainer.register() which registered the service worker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/scope)
     */
    readonly scope: string;
    /**
     * The **`updateViaCache`** read-only property of the ServiceWorkerRegistration interface returns the value of the setting used to determine the circumstances in which the browser will consult the HTTP cache when it tries to update the service worker or any scripts that are imported via importScripts().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/updateViaCache)
     */
    readonly updateViaCache: ServiceWorkerUpdateViaCache;
    /**
     * The **`waiting`** read-only property of the ServiceWorkerRegistration interface returns a service worker whose ServiceWorker.state is installed. This property is initially set to null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/waiting)
     */
    readonly waiting: ServiceWorker | null;
    /**
     * The **`getNotifications()`** method of the ServiceWorkerRegistration interface returns a list of the notifications in the order that they were created from the current origin via the current service worker registration. Origins can have many active but differently-scoped service worker registrations. Notifications created by one service worker on the same origin will not be available to other active service workers on that same origin.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/getNotifications)
     */
    getNotifications(filter?: GetNotificationOptions): Promise<Notification[]>;
    /**
     * The **`showNotification()`** method of the ServiceWorkerRegistration interface creates a notification on an active service worker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/showNotification)
     */
    showNotification(title: string, options?: NotificationOptions): Promise<void>;
    /**
     * The **`unregister()`** method of the ServiceWorkerRegistration interface unregisters the service worker registration and returns a Promise. The promise will resolve to false if no registration was found, otherwise it resolves to true irrespective of whether unregistration happened or not (it may not unregister if someone else just called ServiceWorkerContainer.register() with the same scope.) The service worker will finish any ongoing operations before it is unregistered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/unregister)
     */
    unregister(): Promise<boolean>;
    /**
     * The **`update()`** method of the ServiceWorkerRegistration interface attempts to update the service worker. It fetches the worker's script URL, and if the new worker is not byte-by-byte identical to the current worker, it installs the new worker. The fetch of the worker bypasses any browser caches if the previous fetch occurred over 24 hours ago.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/update)
     */
    update(): Promise<ServiceWorkerRegistration>;
    addEventListener<K extends keyof ServiceWorkerRegistrationEventMap>(type: K, listener: (this: ServiceWorkerRegistration, ev: ServiceWorkerRegistrationEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ServiceWorkerRegistrationEventMap>(type: K, listener: (this: ServiceWorkerRegistration, ev: ServiceWorkerRegistrationEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var ServiceWorkerRegistration: {
    prototype: ServiceWorkerRegistration;
    new(): ServiceWorkerRegistration;
};

interface ShadowRootEventMap {
    "slotchange": Event;
}

/**
 * The **`ShadowRoot`** interface of the Shadow DOM API is the root node of a DOM subtree that is rendered separately from a document's main DOM tree.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot)
 */
interface ShadowRoot extends DocumentFragment, DocumentOrShadowRoot {
    /**
     * The **`clonable`** read-only property of the ShadowRoot interface returns true if the shadow root is clonable, and false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/clonable)
     */
    readonly clonable: boolean;
    /**
     * The **`delegatesFocus`** read-only property of the ShadowRoot interface returns true if the shadow root delegates focus, and false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/delegatesFocus)
     */
    readonly delegatesFocus: boolean;
    /**
     * The **`host`** read-only property of the ShadowRoot returns a reference to the DOM element the ShadowRoot is attached to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/host)
     */
    readonly host: Element;
    /**
     * The **`innerHTML`** property of the ShadowRoot interface gets or sets the HTML markup to the DOM tree inside the ShadowRoot.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/innerHTML)
     */
    innerHTML: string;
    /**
     * The **`mode`** read-only property of the ShadowRoot specifies its mode — either open or closed. This defines whether or not the shadow root's internal features are accessible from JavaScript.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/mode)
     */
    readonly mode: ShadowRootMode;
    onslotchange: ((this: ShadowRoot, ev: Event) => any) | null;
    /**
     * The **`serializable`** read-only property of the ShadowRoot interface returns true if the shadow root is serializable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/serializable)
     */
    readonly serializable: boolean;
    /**
     * The read-only **`slotAssignment`** property of the ShadowRoot interface returns the slot assignment mode for the shadow DOM tree. Nodes are either automatically assigned (named) or manually assigned (manual). The value of this property defined using the slotAssignment option when calling Element.attachShadow().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/slotAssignment)
     */
    readonly slotAssignment: SlotAssignmentMode;
    /**
     * The **`getHTML()`** method of the ShadowRoot interface is used to serialize a shadow root's DOM to an HTML string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/getHTML)
     */
    getHTML(options?: GetHTMLOptions): string;
    /**
     * The **`setHTMLUnsafe()`** method of the ShadowRoot interface can be used to parse HTML input into a DocumentFragment, optionally filtering out unwanted elements and attributes, and then use it to replace the existing tree in the Shadow DOM.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ShadowRoot/setHTMLUnsafe)
     */
    setHTMLUnsafe(html: string): void;
    addEventListener<K extends keyof ShadowRootEventMap>(type: K, listener: (this: ShadowRoot, ev: ShadowRootEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof ShadowRootEventMap>(type: K, listener: (this: ShadowRoot, ev: ShadowRootEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var ShadowRoot: {
    prototype: ShadowRoot;
    new(): ShadowRoot;
};

/**
 * The **`SharedWorker`** interface represents a specific kind of worker that can be accessed from several browsing contexts, such as multiple windows or iframes. Shared workers implement a different interface than dedicated workers, have a different global scope (SharedWorkerGlobalScope), and their constructor is not exposed in DedicatedWorkerGlobalScope, so they cannot be instantiated from dedicated workers.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SharedWorker)
 */
interface SharedWorker extends EventTarget, AbstractWorker {
    /**
     * The **`port`** property of the SharedWorker interface returns a MessagePort object used to communicate and control the shared worker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SharedWorker/port)
     */
    readonly port: MessagePort;
    addEventListener<K extends keyof AbstractWorkerEventMap>(type: K, listener: (this: SharedWorker, ev: AbstractWorkerEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AbstractWorkerEventMap>(type: K, listener: (this: SharedWorker, ev: AbstractWorkerEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SharedWorker: {
    prototype: SharedWorker;
    new(scriptURL: string | URL, options?: string | WorkerOptions): SharedWorker;
};

interface Slottable {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Element/assignedSlot) */
    readonly assignedSlot: HTMLSlotElement | null;
}

interface SourceBufferEventMap {
    "abort": Event;
    "error": Event;
    "update": Event;
    "updateend": Event;
    "updatestart": Event;
}

/**
 * The **`SourceBuffer`** interface represents a chunk of media to be passed into an HTMLMediaElement and played, via a MediaSource object. This can be made up of one or several media segments.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer)
 */
interface SourceBuffer extends EventTarget {
    /**
     * The **`appendWindowEnd`** property of the SourceBuffer interface controls the timestamp for the end of the append window, a timestamp range that can be used to filter what media data is appended to the SourceBuffer. Coded media frames with timestamps within this range will be appended, whereas those outside the range will be filtered out.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/appendWindowEnd)
     */
    appendWindowEnd: number;
    /**
     * The **`appendWindowStart`** property of the SourceBuffer interface controls the timestamp for the start of the append window, a timestamp range that can be used to filter what media data is appended to the SourceBuffer. Coded media frames with timestamps within this range will be appended, whereas those outside the range will be filtered out.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/appendWindowStart)
     */
    appendWindowStart: number;
    /**
     * The **`buffered`** read-only property of the SourceBuffer interface returns the time ranges that are currently buffered in the SourceBuffer as a normalized TimeRanges object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/buffered)
     */
    readonly buffered: TimeRanges;
    /**
     * The **`mode`** property of the SourceBuffer interface controls whether media segments can be appended to the SourceBuffer in any order, or in a strict sequence.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/mode)
     */
    mode: AppendMode;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/abort_event) */
    onabort: ((this: SourceBuffer, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/error_event) */
    onerror: ((this: SourceBuffer, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/update_event) */
    onupdate: ((this: SourceBuffer, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/updateend_event) */
    onupdateend: ((this: SourceBuffer, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/updatestart_event) */
    onupdatestart: ((this: SourceBuffer, ev: Event) => any) | null;
    /**
     * The **`timestampOffset`** property of the SourceBuffer interface controls the offset applied to timestamps inside media segments that are appended to the SourceBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/timestampOffset)
     */
    timestampOffset: number;
    /**
     * The **`updating`** read-only property of the SourceBuffer interface indicates whether the SourceBuffer is currently being updated — i.e., whether an appendBuffer() or remove() operation is currently in progress.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/updating)
     */
    readonly updating: boolean;
    /**
     * The **`abort()`** method of the SourceBuffer interface aborts the current segment and resets the segment parser.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/abort)
     */
    abort(): void;
    /**
     * The **`appendBuffer()`** method of the SourceBuffer interface appends media segment data from an ArrayBuffer, a TypedArray or a DataView object to the SourceBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/appendBuffer)
     */
    appendBuffer(data: BufferSource): void;
    /**
     * The **`changeType()`** method of the SourceBuffer interface sets the MIME type that future calls to appendBuffer() should expect the new media data to conform to. This makes it possible to change codecs or container type mid-stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/changeType)
     */
    changeType(type: string): void;
    /**
     * The **`remove()`** method of the SourceBuffer interface removes media segments within a specific time range from the SourceBuffer. This method can only be called when SourceBuffer.updating equals false. If SourceBuffer.updating is not equal to false, call SourceBuffer.abort().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBuffer/remove)
     */
    remove(start: number, end: number): void;
    addEventListener<K extends keyof SourceBufferEventMap>(type: K, listener: (this: SourceBuffer, ev: SourceBufferEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SourceBufferEventMap>(type: K, listener: (this: SourceBuffer, ev: SourceBufferEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SourceBuffer: {
    prototype: SourceBuffer;
    new(): SourceBuffer;
};

interface SourceBufferListEventMap {
    "addsourcebuffer": Event;
    "removesourcebuffer": Event;
}

/**
 * The **`SourceBufferList`** interface represents a simple container list for multiple SourceBuffer objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBufferList)
 */
interface SourceBufferList extends EventTarget {
    /**
     * The **`length`** read-only property of the SourceBufferList interface returns the number of SourceBuffer objects in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SourceBufferList/length)
     */
    readonly length: number;
    onaddsourcebuffer: ((this: SourceBufferList, ev: Event) => any) | null;
    onremovesourcebuffer: ((this: SourceBufferList, ev: Event) => any) | null;
    addEventListener<K extends keyof SourceBufferListEventMap>(type: K, listener: (this: SourceBufferList, ev: SourceBufferListEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SourceBufferListEventMap>(type: K, listener: (this: SourceBufferList, ev: SourceBufferListEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
    [index: number]: SourceBuffer;
}

declare var SourceBufferList: {
    prototype: SourceBufferList;
    new(): SourceBufferList;
};

/**
 * The **`SpeechRecognitionAlternative`** interface of the Web Speech API represents a single word that has been recognized by the speech recognition service.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionAlternative)
 */
interface SpeechRecognitionAlternative {
    /**
     * The **`confidence`** read-only property of the SpeechRecognitionResult interface returns a numeric estimate of how confident the speech recognition system is that the recognition is correct.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionAlternative/confidence)
     */
    readonly confidence: number;
    /**
     * The **`transcript`** read-only property of the SpeechRecognitionResult interface returns a string containing the transcript of the recognized word(s).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionAlternative/transcript)
     */
    readonly transcript: string;
}

declare var SpeechRecognitionAlternative: {
    prototype: SpeechRecognitionAlternative;
    new(): SpeechRecognitionAlternative;
};

/**
 * The **`SpeechRecognitionErrorEvent`** interface of the Web Speech API represents error messages from the recognition service.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionErrorEvent)
 */
interface SpeechRecognitionErrorEvent extends Event {
    /**
     * The **`error`** read-only property of the SpeechRecognitionErrorEvent interface returns the type of error raised.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionErrorEvent/error)
     */
    readonly error: SpeechRecognitionErrorCode;
    /**
     * The **`message`** read-only property of the SpeechRecognitionErrorEvent interface returns a message describing the error in more detail.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionErrorEvent/message)
     */
    readonly message: string;
}

declare var SpeechRecognitionErrorEvent: {
    prototype: SpeechRecognitionErrorEvent;
    new(type: string, eventInitDict: SpeechRecognitionErrorEventInit): SpeechRecognitionErrorEvent;
};

/**
 * The **`SpeechRecognitionEvent`** interface of the Web Speech API represents the event object for the result and nomatch events, and contains all the data associated with an interim or final speech recognition result.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionEvent)
 */
interface SpeechRecognitionEvent extends Event {
    /**
     * The **`resultIndex`** read-only property of the SpeechRecognitionEvent interface returns the lowest index value result in the SpeechRecognitionResultList "array" that has actually changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionEvent/resultIndex)
     */
    readonly resultIndex: number;
    /**
     * The **`results`** read-only property of the SpeechRecognitionEvent interface returns a SpeechRecognitionResultList object representing all the speech recognition results for the current session.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionEvent/results)
     */
    readonly results: SpeechRecognitionResultList;
}

declare var SpeechRecognitionEvent: {
    prototype: SpeechRecognitionEvent;
    new(type: string, eventInitDict: SpeechRecognitionEventInit): SpeechRecognitionEvent;
};

/**
 * The **`SpeechRecognitionResult`** interface of the Web Speech API represents a single recognition match, which may contain multiple SpeechRecognitionAlternative objects.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResult)
 */
interface SpeechRecognitionResult {
    /**
     * The **`isFinal`** read-only property of the SpeechRecognitionResult interface is a boolean value that states whether this result is final (true) or not (false) — if so, then this is the final time this result will be returned; if not, then this result is an interim result, and may be updated later on.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResult/isFinal)
     */
    readonly isFinal: boolean;
    /**
     * The **`length`** read-only property of the SpeechRecognitionResult interface returns the length of the "array" — the number of SpeechRecognitionAlternative objects contained in the result (also referred to as "n-best alternatives".)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResult/length)
     */
    readonly length: number;
    /**
     * The **`item`** getter of the SpeechRecognitionResult interface is a standard getter that allows SpeechRecognitionAlternative objects within the result to be accessed via array syntax.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResult/item)
     */
    item(index: number): SpeechRecognitionAlternative;
    [index: number]: SpeechRecognitionAlternative;
}

declare var SpeechRecognitionResult: {
    prototype: SpeechRecognitionResult;
    new(): SpeechRecognitionResult;
};

/**
 * The **`SpeechRecognitionResultList`** interface of the Web Speech API represents a list of SpeechRecognitionResult objects, or a single one if results are being captured in non-continuous mode.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResultList)
 */
interface SpeechRecognitionResultList {
    /**
     * The **`length`** read-only property of the SpeechRecognitionResultList interface returns the length of the "array" — the number of SpeechRecognitionResult objects in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResultList/length)
     */
    readonly length: number;
    /**
     * The **`item`** getter of the SpeechRecognitionResultList interface is a standard getter — it allows SpeechRecognitionResult objects in the list to be accessed via array syntax.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechRecognitionResultList/item)
     */
    item(index: number): SpeechRecognitionResult;
    [index: number]: SpeechRecognitionResult;
}

declare var SpeechRecognitionResultList: {
    prototype: SpeechRecognitionResultList;
    new(): SpeechRecognitionResultList;
};

interface SpeechSynthesisEventMap {
    "voiceschanged": Event;
}

/**
 * The **`SpeechSynthesis`** interface of the Web Speech API is the controller interface for the speech service; this can be used to retrieve information about the synthesis voices available on the device, start and pause speech, and other commands besides.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis)
 */
interface SpeechSynthesis extends EventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/voiceschanged_event) */
    onvoiceschanged: ((this: SpeechSynthesis, ev: Event) => any) | null;
    /**
     * The **`paused`** read-only property of the SpeechSynthesis interface is a boolean value that returns true if the SpeechSynthesis object is in a paused state, or false if not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/paused)
     */
    readonly paused: boolean;
    /**
     * The **`pending`** read-only property of the SpeechSynthesis interface is a boolean value that returns true if the utterance queue contains as-yet-unspoken utterances.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/pending)
     */
    readonly pending: boolean;
    /**
     * The **`speaking`** read-only property of the SpeechSynthesis interface is a boolean value that returns true if an utterance is currently in the process of being spoken — even if SpeechSynthesis is in a paused state.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/speaking)
     */
    readonly speaking: boolean;
    /**
     * The **`cancel()`** method of the SpeechSynthesis interface removes all utterances from the utterance queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/cancel)
     */
    cancel(): void;
    /**
     * The **`getVoices()`** method of the SpeechSynthesis interface returns a list of SpeechSynthesisVoice objects representing all the available voices on the current device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/getVoices)
     */
    getVoices(): SpeechSynthesisVoice[];
    /**
     * The **`pause()`** method of the SpeechSynthesis interface puts the SpeechSynthesis object into a paused state.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/pause)
     */
    pause(): void;
    /**
     * The **`resume()`** method of the SpeechSynthesis interface puts the SpeechSynthesis object into a non-paused state: resumes it if it was already paused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/resume)
     */
    resume(): void;
    /**
     * The **`speak()`** method of the SpeechSynthesis interface adds an utterance to the utterance queue; it will be spoken when any other utterances queued before it have been spoken.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesis/speak)
     */
    speak(utterance: SpeechSynthesisUtterance): void;
    addEventListener<K extends keyof SpeechSynthesisEventMap>(type: K, listener: (this: SpeechSynthesis, ev: SpeechSynthesisEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SpeechSynthesisEventMap>(type: K, listener: (this: SpeechSynthesis, ev: SpeechSynthesisEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SpeechSynthesis: {
    prototype: SpeechSynthesis;
    new(): SpeechSynthesis;
};

/**
 * The **`SpeechSynthesisErrorEvent`** interface of the Web Speech API contains information about any errors that occur while processing SpeechSynthesisUtterance objects in the speech service.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisErrorEvent)
 */
interface SpeechSynthesisErrorEvent extends SpeechSynthesisEvent {
    /**
     * The **`error`** property of the SpeechSynthesisErrorEvent interface returns an error code indicating what has gone wrong with a speech synthesis attempt.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisErrorEvent/error)
     */
    readonly error: SpeechSynthesisErrorCode;
}

declare var SpeechSynthesisErrorEvent: {
    prototype: SpeechSynthesisErrorEvent;
    new(type: string, eventInitDict: SpeechSynthesisErrorEventInit): SpeechSynthesisErrorEvent;
};

/**
 * The **`SpeechSynthesisEvent`** interface of the Web Speech API contains information about the current state of SpeechSynthesisUtterance objects that have been processed in the speech service.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisEvent)
 */
interface SpeechSynthesisEvent extends Event {
    /**
     * The **`charIndex`** read-only property of the SpeechSynthesisUtterance interface returns the index position of the character in SpeechSynthesisUtterance.text that was being spoken when the event was triggered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisEvent/charIndex)
     */
    readonly charIndex: number;
    /**
     * The read-only **`charLength`** property of the SpeechSynthesisEvent interface returns the number of characters left to be spoken after the character at the charIndex position.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisEvent/charLength)
     */
    readonly charLength: number;
    /**
     * The **`elapsedTime`** read-only property of the SpeechSynthesisEvent returns the elapsed time in seconds, after the SpeechSynthesisUtterance.text started being spoken, at which the event was triggered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisEvent/elapsedTime)
     */
    readonly elapsedTime: number;
    /**
     * The **`name`** read-only property of the SpeechSynthesisUtterance interface returns the name associated with certain types of events occurring as the SpeechSynthesisUtterance.text is being spoken: the name of the SSML marker reached in the case of a mark event, or the type of boundary reached in the case of a boundary event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisEvent/name)
     */
    readonly name: string;
    /**
     * The **`utterance`** read-only property of the SpeechSynthesisUtterance interface returns the SpeechSynthesisUtterance instance that the event was triggered on.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisEvent/utterance)
     */
    readonly utterance: SpeechSynthesisUtterance;
}

declare var SpeechSynthesisEvent: {
    prototype: SpeechSynthesisEvent;
    new(type: string, eventInitDict: SpeechSynthesisEventInit): SpeechSynthesisEvent;
};

interface SpeechSynthesisUtteranceEventMap {
    "boundary": SpeechSynthesisEvent;
    "end": SpeechSynthesisEvent;
    "error": SpeechSynthesisErrorEvent;
    "mark": SpeechSynthesisEvent;
    "pause": SpeechSynthesisEvent;
    "resume": SpeechSynthesisEvent;
    "start": SpeechSynthesisEvent;
}

/**
 * The **`SpeechSynthesisUtterance`** interface of the Web Speech API represents a speech request. It contains the content the speech service should read and information about how to read it (e.g., language, pitch and volume.)
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance)
 */
interface SpeechSynthesisUtterance extends EventTarget {
    /**
     * The **`lang`** property of the SpeechSynthesisUtterance interface gets and sets the language of the utterance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/lang)
     */
    lang: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/boundary_event) */
    onboundary: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/end_event) */
    onend: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/error_event) */
    onerror: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisErrorEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/mark_event) */
    onmark: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/pause_event) */
    onpause: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/resume_event) */
    onresume: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/start_event) */
    onstart: ((this: SpeechSynthesisUtterance, ev: SpeechSynthesisEvent) => any) | null;
    /**
     * The **`pitch`** property of the SpeechSynthesisUtterance interface gets and sets the pitch at which the utterance will be spoken at.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/pitch)
     */
    pitch: number;
    /**
     * The **`rate`** property of the SpeechSynthesisUtterance interface gets and sets the speed at which the utterance will be spoken at.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/rate)
     */
    rate: number;
    /**
     * The **`text`** property of the SpeechSynthesisUtterance interface gets and sets the text that will be synthesized when the utterance is spoken.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/text)
     */
    text: string;
    /**
     * The **`voice`** property of the SpeechSynthesisUtterance interface gets and sets the voice that will be used to speak the utterance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/voice)
     */
    voice: SpeechSynthesisVoice | null;
    /**
     * The **`volume`** property of the SpeechSynthesisUtterance interface gets and sets the volume that the utterance will be spoken at.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisUtterance/volume)
     */
    volume: number;
    addEventListener<K extends keyof SpeechSynthesisUtteranceEventMap>(type: K, listener: (this: SpeechSynthesisUtterance, ev: SpeechSynthesisUtteranceEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof SpeechSynthesisUtteranceEventMap>(type: K, listener: (this: SpeechSynthesisUtterance, ev: SpeechSynthesisUtteranceEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var SpeechSynthesisUtterance: {
    prototype: SpeechSynthesisUtterance;
    new(text?: string): SpeechSynthesisUtterance;
};

/**
 * The **`SpeechSynthesisVoice`** interface of the Web Speech API represents a voice that the system supports. Every SpeechSynthesisVoice has its own relative speech service including information about language, name and URI.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisVoice)
 */
interface SpeechSynthesisVoice {
    /**
     * The **`default`** read-only property of the SpeechSynthesisVoice interface returns a boolean value indicating whether the voice is the default voice for the current app (true), or not (false.)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisVoice/default)
     */
    readonly default: boolean;
    /**
     * The **`lang`** read-only property of the SpeechSynthesisVoice interface returns a BCP 47 language tag indicating the language of the voice.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisVoice/lang)
     */
    readonly lang: string;
    /**
     * The **`localService`** read-only property of the SpeechSynthesisVoice interface returns a boolean value indicating whether the voice is supplied by a local speech synthesizer service (true), or a remote speech synthesizer service (false.)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisVoice/localService)
     */
    readonly localService: boolean;
    /**
     * The **`name`** read-only property of the SpeechSynthesisVoice interface returns a human-readable name that represents the voice.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisVoice/name)
     */
    readonly name: string;
    /**
     * The **`voiceURI`** read-only property of the SpeechSynthesisVoice interface returns the type of URI and location of the speech synthesis service for this voice.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SpeechSynthesisVoice/voiceURI)
     */
    readonly voiceURI: string;
}

declare var SpeechSynthesisVoice: {
    prototype: SpeechSynthesisVoice;
    new(): SpeechSynthesisVoice;
};

/**
 * The DOM **`StaticRange`** interface extends AbstractRange to provide a method to specify a range of content in the DOM whose contents don't update to reflect changes which occur within the DOM tree.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StaticRange)
 */
interface StaticRange extends AbstractRange {
}

declare var StaticRange: {
    prototype: StaticRange;
    new(init: StaticRangeInit): StaticRange;
};

/**
 * The **`StereoPannerNode`** interface of the Web Audio API represents a simple stereo panner node that can be used to pan an audio stream left or right. It is an AudioNode audio-processing module that positions an incoming audio stream in a stereo image using a low-cost equal-power panning algorithm.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StereoPannerNode)
 */
interface StereoPannerNode extends AudioNode {
    /**
     * The **`pan`** property of the StereoPannerNode interface is an a-rate AudioParam representing the amount of panning to apply. The value can range between -1 (full left pan) and 1 (full right pan).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StereoPannerNode/pan)
     */
    readonly pan: AudioParam;
}

declare var StereoPannerNode: {
    prototype: StereoPannerNode;
    new(context: BaseAudioContext, options?: StereoPannerOptions): StereoPannerNode;
};

/**
 * The **`Storage`** interface of the Web Storage API provides access to a particular domain's session or local storage. It allows, for example, the addition, modification, or deletion of stored data items.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage)
 */
interface Storage {
    /**
     * The **`length`** read-only property of the Storage interface returns the number of data items stored in a given Storage object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage/length)
     */
    readonly length: number;
    /**
     * The **`clear()`** method of the Storage interface clears all keys stored in a given Storage object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage/clear)
     */
    clear(): void;
    /**
     * The **`getItem()`** method of the Storage interface, when passed a key name, will return that key's value, or null if the key does not exist, in the given Storage object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage/getItem)
     */
    getItem(key: string): string | null;
    /**
     * The **`key()`** method of the Storage interface, when passed a number n, returns the name of the nth key in a given Storage object. The order of keys is user-agent defined, so you should not rely on it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage/key)
     */
    key(index: number): string | null;
    /**
     * The **`removeItem()`** method of the Storage interface, when passed a key name, will remove that key from the given Storage object if it exists. The Storage interface of the Web Storage API provides access to a particular domain's session or local storage.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage/removeItem)
     */
    removeItem(key: string): void;
    /**
     * The **`setItem()`** method of the Storage interface, when passed a key name and value, will add that key to the given Storage object, or update that key's value if it already exists.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Storage/setItem)
     */
    setItem(key: string, value: string): void;
    [name: string]: any;
}

declare var Storage: {
    prototype: Storage;
    new(): Storage;
};

/**
 * The **`StorageEvent`** interface is implemented by the storage event, which is sent to a window when a storage area the window has access to is changed within the context of another document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent)
 */
interface StorageEvent extends Event {
    /**
     * The **`key`** property of the StorageEvent interface returns the key for the storage item that was changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent/key)
     */
    readonly key: string | null;
    /**
     * The **`newValue`** property of the StorageEvent interface returns the new value of the storage item whose value was changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent/newValue)
     */
    readonly newValue: string | null;
    /**
     * The **`oldValue`** property of the StorageEvent interface returns the original value of the storage item whose value changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent/oldValue)
     */
    readonly oldValue: string | null;
    /**
     * The **`storageArea`** property of the StorageEvent interface returns the storage object that was affected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent/storageArea)
     */
    readonly storageArea: Storage | null;
    /**
     * The **`url`** property of the StorageEvent interface returns the URL of the document whose storage changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent/url)
     */
    readonly url: string;
    /**
     * The **`StorageEvent.initStorageEvent()`** method is used to initialize the value of a StorageEvent.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageEvent/initStorageEvent)
     */
    initStorageEvent(type: string, bubbles?: boolean, cancelable?: boolean, key?: string | null, oldValue?: string | null, newValue?: string | null, url?: string | URL, storageArea?: Storage | null): void;
}

declare var StorageEvent: {
    prototype: StorageEvent;
    new(type: string, eventInitDict?: StorageEventInit): StorageEvent;
};

/**
 * The **`StorageManager`** interface of the Storage API provides an interface for managing persistence permissions and estimating available storage. You can get a reference to this interface using either navigator.storage or WorkerNavigator.storage.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageManager)
 */
interface StorageManager {
    /**
     * The **`estimate()`** method of the StorageManager interface asks the Storage Manager for how much storage the current origin takes up (usage), and how much space is available (quota).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageManager/estimate)
     */
    estimate(): Promise<StorageEstimate>;
    /**
     * The **`getDirectory()`** method of the StorageManager interface is used to obtain a reference to a FileSystemDirectoryHandle object allowing access to a directory and its contents, stored in the origin private file system (OPFS).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageManager/getDirectory)
     */
    getDirectory(): Promise<FileSystemDirectoryHandle>;
    /**
     * The **`persist()`** method of the StorageManager interface requests permission to use persistent storage, and returns a Promise that resolves to true if permission is granted and bucket mode is persistent, and false otherwise. The browser may or may not honor the request, depending on browser-specific rules. (For more details, see the guide to Storage quotas and eviction criteria.)
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageManager/persist)
     */
    persist(): Promise<boolean>;
    /**
     * The **`persisted()`** method of the StorageManager interface returns a Promise that resolves to true if your site's storage bucket is persistent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StorageManager/persisted)
     */
    persisted(): Promise<boolean>;
}

declare var StorageManager: {
    prototype: StorageManager;
    new(): StorageManager;
};

/**
 * The **`StylePropertyMap`** interface of the CSS Typed Object Model API provides a representation of a CSS declaration block that is an alternative to CSSStyleDeclaration.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMap)
 */
interface StylePropertyMap extends StylePropertyMapReadOnly {
    /**
     * The **`append()`** method of the StylePropertyMap interface adds the passed CSS value to the StylePropertyMap with the given property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMap/append)
     */
    append(property: string, ...values: (CSSStyleValue | string)[]): void;
    /**
     * The **`clear()`** method of the StylePropertyMap interface removes all declarations in the StylePropertyMap.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMap/clear)
     */
    clear(): void;
    /**
     * The **`delete()`** method of the StylePropertyMap interface removes the CSS declaration with the given property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMap/delete)
     */
    delete(property: string): void;
    /**
     * The **`set()`** method of the StylePropertyMap interface changes the CSS declaration with the given property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMap/set)
     */
    set(property: string, ...values: (CSSStyleValue | string)[]): void;
}

declare var StylePropertyMap: {
    prototype: StylePropertyMap;
    new(): StylePropertyMap;
};

/**
 * The **`StylePropertyMapReadOnly`** interface of the CSS Typed Object Model API provides a read-only representation of a CSS declaration block that is an alternative to CSSStyleDeclaration. Retrieve an instance of this interface using Element.computedStyleMap().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMapReadOnly)
 */
interface StylePropertyMapReadOnly {
    /**
     * The **`size`** read-only property of the StylePropertyMapReadOnly interface returns an unsigned long integer containing the size of the StylePropertyMapReadOnly object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMapReadOnly/size)
     */
    readonly size: number;
    /**
     * The **`get()`** method of the StylePropertyMapReadOnly interface returns a CSSStyleValue object for the first value of the specified property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMapReadOnly/get)
     */
    get(property: string): undefined | CSSStyleValue;
    /**
     * The **`getAll()`** method of the StylePropertyMapReadOnly interface returns an array of CSSStyleValue objects containing the values for the provided property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMapReadOnly/getAll)
     */
    getAll(property: string): CSSStyleValue[];
    /**
     * The **`has()`** method of the StylePropertyMapReadOnly interface indicates whether the specified property is in the StylePropertyMapReadOnly object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StylePropertyMapReadOnly/has)
     */
    has(property: string): boolean;
    forEach(callbackfn: (value: CSSStyleValue[], key: string, parent: StylePropertyMapReadOnly) => void, thisArg?: any): void;
}

declare var StylePropertyMapReadOnly: {
    prototype: StylePropertyMapReadOnly;
    new(): StylePropertyMapReadOnly;
};

/**
 * An object implementing the **`StyleSheet`** interface represents a single style sheet. CSS style sheets will further implement the more specialized CSSStyleSheet interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet)
 */
interface StyleSheet {
    /**
     * The **`disabled`** property of the StyleSheet interface determines whether the style sheet is prevented from applying to the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/disabled)
     */
    disabled: boolean;
    /**
     * The **`href`** property of the StyleSheet interface returns the location of the style sheet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/href)
     */
    readonly href: string | null;
    /**
     * The read-only **`media`** property of the StyleSheet interface contains a MediaList object representing the intended destination media for style information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/media)
     */
    get media(): MediaList;
    set media(mediaText: string);
    /**
     * The **`ownerNode`** property of the StyleSheet interface returns the node that associates this style sheet with the document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/ownerNode)
     */
    readonly ownerNode: Element | ProcessingInstruction | null;
    /**
     * The **`parentStyleSheet`** property of the StyleSheet interface returns the style sheet, if any, that is including the given style sheet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/parentStyleSheet)
     */
    readonly parentStyleSheet: CSSStyleSheet | null;
    /**
     * The **`title`** property of the StyleSheet interface returns the advisory title of the current style sheet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/title)
     */
    readonly title: string | null;
    /**
     * The **`type`** property of the StyleSheet interface specifies the style sheet language for the given style sheet.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheet/type)
     */
    readonly type: string;
}

declare var StyleSheet: {
    prototype: StyleSheet;
    new(): StyleSheet;
};

/**
 * The **`StyleSheetList`** interface represents a list of CSSStyleSheet objects. An instance of this object can be returned by Document.styleSheets.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheetList)
 */
interface StyleSheetList {
    /**
     * The **`length`** read-only property of the StyleSheetList interface returns the number of CSSStyleSheet objects in the collection.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheetList/length)
     */
    readonly length: number;
    /**
     * The **`item()`** method of the StyleSheetList interface returns a single CSSStyleSheet object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/StyleSheetList/item)
     */
    item(index: number): CSSStyleSheet | null;
    [index: number]: CSSStyleSheet;
}

declare var StyleSheetList: {
    prototype: StyleSheetList;
    new(): StyleSheetList;
};

/**
 * The **`SubmitEvent`** interface defines the object used to represent an HTML form's submit event. This event is fired at the <form> when the form's submit action is invoked.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubmitEvent)
 */
interface SubmitEvent extends Event {
    /**
     * The read-only **`submitter`** property found on the SubmitEvent interface specifies the submit button or other element that was invoked to cause the form to be submitted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubmitEvent/submitter)
     */
    readonly submitter: HTMLElement | null;
}

declare var SubmitEvent: {
    prototype: SubmitEvent;
    new(type: string, eventInitDict?: SubmitEventInit): SubmitEvent;
};

/**
 * The **`SubtleCrypto`** interface of the Web Crypto API provides a number of low-level cryptographic functions.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto)
 */
interface SubtleCrypto {
    /**
     * The **`decrypt()`** method of the SubtleCrypto interface decrypts some encrypted data. It takes as arguments a key to decrypt with, some optional extra parameters, and the data to decrypt (also known as "ciphertext"). It returns a Promise which will be fulfilled with the decrypted data (also known as "plaintext").
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/decrypt)
     */
    decrypt(algorithm: AlgorithmIdentifier | RsaOaepParams | AesCtrParams | AesCbcParams | AesGcmParams, key: CryptoKey, data: BufferSource): Promise<ArrayBuffer>;
    /**
     * The **`deriveBits()`** method of the SubtleCrypto interface can be used to derive an array of bits from a base key.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/deriveBits)
     */
    deriveBits(algorithm: AlgorithmIdentifier | EcdhKeyDeriveParams | HkdfParams | Pbkdf2Params, baseKey: CryptoKey, length?: number | null): Promise<ArrayBuffer>;
    /**
     * The **`deriveKey()`** method of the SubtleCrypto interface can be used to derive a secret key from a master key.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/deriveKey)
     */
    deriveKey(algorithm: AlgorithmIdentifier | EcdhKeyDeriveParams | HkdfParams | Pbkdf2Params, baseKey: CryptoKey, derivedKeyType: AlgorithmIdentifier | AesDerivedKeyParams | HmacImportParams | HkdfParams | Pbkdf2Params, extractable: boolean, keyUsages: KeyUsage[]): Promise<CryptoKey>;
    /**
     * The **`digest()`** method of the SubtleCrypto interface generates a digest of the given data, using the specified hash function. A digest is a short fixed-length value derived from some variable-length input. Cryptographic digests should exhibit collision-resistance, meaning that it's hard to come up with two different inputs that have the same digest value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/digest)
     */
    digest(algorithm: AlgorithmIdentifier, data: BufferSource): Promise<ArrayBuffer>;
    /**
     * The **`encrypt()`** method of the SubtleCrypto interface encrypts data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/encrypt)
     */
    encrypt(algorithm: AlgorithmIdentifier | RsaOaepParams | AesCtrParams | AesCbcParams | AesGcmParams, key: CryptoKey, data: BufferSource): Promise<ArrayBuffer>;
    /**
     * The **`exportKey()`** method of the SubtleCrypto interface exports a key: that is, it takes as input a CryptoKey object and gives you the key in an external, portable format.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/exportKey)
     */
    exportKey(format: "jwk", key: CryptoKey): Promise<JsonWebKey>;
    exportKey(format: Exclude<KeyFormat, "jwk">, key: CryptoKey): Promise<ArrayBuffer>;
    exportKey(format: KeyFormat, key: CryptoKey): Promise<ArrayBuffer | JsonWebKey>;
    /**
     * The **`generateKey()`** method of the SubtleCrypto interface is used to generate a new key (for symmetric algorithms) or key pair (for public-key algorithms).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/generateKey)
     */
    generateKey(algorithm: "Ed25519" | { name: "Ed25519" }, extractable: boolean, keyUsages: ReadonlyArray<"sign" | "verify">): Promise<CryptoKeyPair>;
    generateKey(algorithm: "X25519" | { name: "X25519" }, extractable: boolean, keyUsages: ReadonlyArray<"deriveBits" | "deriveKey">): Promise<CryptoKeyPair>;
    generateKey(algorithm: RsaHashedKeyGenParams | EcKeyGenParams, extractable: boolean, keyUsages: ReadonlyArray<KeyUsage>): Promise<CryptoKeyPair>;
    generateKey(algorithm: AesKeyGenParams | HmacKeyGenParams | Pbkdf2Params, extractable: boolean, keyUsages: ReadonlyArray<KeyUsage>): Promise<CryptoKey>;
    generateKey(algorithm: AlgorithmIdentifier, extractable: boolean, keyUsages: KeyUsage[]): Promise<CryptoKeyPair | CryptoKey>;
    /**
     * The **`importKey()`** method of the SubtleCrypto interface imports a key: that is, it takes as input a key in an external, portable format and gives you a CryptoKey object that you can use in the Web Crypto API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/importKey)
     */
    importKey(format: "jwk", keyData: JsonWebKey, algorithm: AlgorithmIdentifier | RsaHashedImportParams | EcKeyImportParams | HmacImportParams | AesKeyAlgorithm, extractable: boolean, keyUsages: ReadonlyArray<KeyUsage>): Promise<CryptoKey>;
    importKey(format: Exclude<KeyFormat, "jwk">, keyData: BufferSource, algorithm: AlgorithmIdentifier | RsaHashedImportParams | EcKeyImportParams | HmacImportParams | AesKeyAlgorithm, extractable: boolean, keyUsages: KeyUsage[]): Promise<CryptoKey>;
    /**
     * The **`sign()`** method of the SubtleCrypto interface generates a digital signature.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/sign)
     */
    sign(algorithm: AlgorithmIdentifier | RsaPssParams | EcdsaParams, key: CryptoKey, data: BufferSource): Promise<ArrayBuffer>;
    /**
     * The **`unwrapKey()`** method of the SubtleCrypto interface "unwraps" a key. This means that it takes as its input a key that has been exported and then encrypted (also called "wrapped"). It decrypts the key and then imports it, returning a CryptoKey object that can be used in the Web Crypto API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/unwrapKey)
     */
    unwrapKey(format: KeyFormat, wrappedKey: BufferSource, unwrappingKey: CryptoKey, unwrapAlgorithm: AlgorithmIdentifier | RsaOaepParams | AesCtrParams | AesCbcParams | AesGcmParams, unwrappedKeyAlgorithm: AlgorithmIdentifier | RsaHashedImportParams | EcKeyImportParams | HmacImportParams | AesKeyAlgorithm, extractable: boolean, keyUsages: KeyUsage[]): Promise<CryptoKey>;
    /**
     * The **`verify()`** method of the SubtleCrypto interface verifies a digital signature.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/verify)
     */
    verify(algorithm: AlgorithmIdentifier | RsaPssParams | EcdsaParams, key: CryptoKey, signature: BufferSource, data: BufferSource): Promise<boolean>;
    /**
     * The **`wrapKey()`** method of the SubtleCrypto interface "wraps" a key. This means that it exports the key in an external, portable format, then encrypts the exported key. Wrapping a key helps protect it in untrusted environments, such as inside an otherwise unprotected data store or in transmission over an unprotected network.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/SubtleCrypto/wrapKey)
     */
    wrapKey(format: KeyFormat, key: CryptoKey, wrappingKey: CryptoKey, wrapAlgorithm: AlgorithmIdentifier | RsaOaepParams | AesCtrParams | AesCbcParams | AesGcmParams): Promise<ArrayBuffer>;
}

declare var SubtleCrypto: {
    prototype: SubtleCrypto;
    new(): SubtleCrypto;
};

/**
 * The **`TaskController`** interface of the Prioritized Task Scheduling API represents a controller object that can be used to both abort and change the priority of one or more prioritized tasks. If there is no need to change task priorities, then AbortController can be used instead.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskController)
 */
interface TaskController extends AbortController {
    /**
     * The **`setPriority()`** method of the TaskController interface can be called to set a new priority for this controller's signal. If a prioritized task is configured to use the signal, this will also change the task priority.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskController/setPriority)
     */
    setPriority(priority: TaskPriority): void;
}

declare var TaskController: {
    prototype: TaskController;
    new(init?: TaskControllerInit): TaskController;
};

/**
 * The **`TaskPriorityChangeEvent`** is the interface for the prioritychange event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskPriorityChangeEvent)
 */
interface TaskPriorityChangeEvent extends Event {
    /**
     * The **`previousPriority`** read-only property of the TaskPriorityChangeEvent interface returns the priority of the corresponding TaskSignal before it was changed and this prioritychange event was emitted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskPriorityChangeEvent/previousPriority)
     */
    readonly previousPriority: TaskPriority;
}

declare var TaskPriorityChangeEvent: {
    prototype: TaskPriorityChangeEvent;
    new(type: string, priorityChangeEventInitDict: TaskPriorityChangeEventInit): TaskPriorityChangeEvent;
};

interface TaskSignalEventMap extends AbortSignalEventMap {
    "prioritychange": TaskPriorityChangeEvent;
}

/**
 * The **`TaskSignal`** interface of the Prioritized Task Scheduling API represents a signal object that allows you to communicate with a prioritized task, and abort it or change the priority (if required) via a TaskController object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskSignal)
 */
interface TaskSignal extends AbortSignal {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskSignal/prioritychange_event) */
    onprioritychange: ((this: TaskSignal, ev: TaskPriorityChangeEvent) => any) | null;
    /**
     * The read-only **`priority`** property of the TaskSignal interface indicates the signal priority.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskSignal/priority)
     */
    readonly priority: TaskPriority;
    addEventListener<K extends keyof TaskSignalEventMap>(type: K, listener: (this: TaskSignal, ev: TaskSignalEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof TaskSignalEventMap>(type: K, listener: (this: TaskSignal, ev: TaskSignalEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var TaskSignal: {
    prototype: TaskSignal;
    new(): TaskSignal;
    /**
     * The **`TaskSignal.any()`** static method takes an iterable of AbortSignal objects and returns a TaskSignal. The returned task signal is aborted when any of the abort signals is aborted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TaskSignal/any_static)
     */
    any(signals: AbortSignal[], init?: TaskSignalAnyInit): TaskSignal;
};

/**
 * The **`Text`** interface represents a text node in a DOM tree.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Text)
 */
interface Text extends CharacterData, Slottable {
    /**
     * The read-only **`wholeText`** property of the Text interface returns the full text of all Text nodes logically adjacent to the node. The text is concatenated in document order. This allows specifying any text node and obtaining all adjacent text as a single string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Text/wholeText)
     */
    readonly wholeText: string;
    /**
     * The **`splitText()`** method of the Text interface breaks the Text node into two nodes at the specified offset, keeping both nodes in the tree as siblings.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Text/splitText)
     */
    splitText(offset: number): Text;
}

declare var Text: {
    prototype: Text;
    new(data?: string): Text;
};

/**
 * The **`TextDecoder`** interface represents a decoder for a specific text encoding, such as UTF-8, ISO-8859-2, or GBK. A decoder takes an array of bytes as input and returns a JavaScript string.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextDecoder)
 */
interface TextDecoder extends TextDecoderCommon {
    /**
     * The **`TextDecoder.decode()`** method returns a string containing text decoded from the buffer passed as a parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextDecoder/decode)
     */
    decode(input?: AllowSharedBufferSource, options?: TextDecodeOptions): string;
}

declare var TextDecoder: {
    prototype: TextDecoder;
    new(label?: string, options?: TextDecoderOptions): TextDecoder;
};

interface TextDecoderCommon {
    /**
     * Returns encoding's name, lowercased.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextDecoder/encoding)
     */
    readonly encoding: string;
    /**
     * Returns true if error mode is "fatal", otherwise false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextDecoder/fatal)
     */
    readonly fatal: boolean;
    /**
     * Returns the value of ignore BOM.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextDecoder/ignoreBOM)
     */
    readonly ignoreBOM: boolean;
}

/**
 * The **`TextDecoderStream`** interface of the Encoding API converts a stream of text in a binary encoding, such as UTF-8 etc., to a stream of strings. It is the streaming equivalent of TextDecoder. It implements the same shape as a TransformStream, allowing it to be used in ReadableStream.pipeThrough() and similar methods.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextDecoderStream)
 */
interface TextDecoderStream extends GenericTransformStream, TextDecoderCommon {
    /** The **`readable`** read-only property of the TextDecoderStream interface returns a ReadableStream that emits decoded strings. */
    readonly readable: ReadableStream<string>;
    /** The **`writable`** read-only property of the TextDecoderStream interface returns a WritableStream that accepts binary data, in the form of ArrayBuffer, TypedArray, or DataView chunks (SharedArrayBuffer and its views are also allowed), to be decoded into strings. */
    readonly writable: WritableStream<BufferSource>;
}

declare var TextDecoderStream: {
    prototype: TextDecoderStream;
    new(label?: string, options?: TextDecoderOptions): TextDecoderStream;
};

/**
 * The **`TextEncoder`** interface enables you to encode a JavaScript string using UTF-8.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEncoder)
 */
interface TextEncoder extends TextEncoderCommon {
    /**
     * The **`TextEncoder.encode()`** method takes a string as input, and returns a Uint8Array containing the string encoded using UTF-8.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEncoder/encode)
     */
    encode(input?: string): Uint8Array<ArrayBuffer>;
    /**
     * The **`TextEncoder.encodeInto()`** method takes a string to encode and a destination Uint8Array to put resulting UTF-8 encoded text into, and returns an object indicating the progress of the encoding. This is potentially more performant than the encode() method — especially when the target buffer is a view into a Wasm heap.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEncoder/encodeInto)
     */
    encodeInto(source: string, destination: Uint8Array<ArrayBufferLike>): TextEncoderEncodeIntoResult;
}

declare var TextEncoder: {
    prototype: TextEncoder;
    new(): TextEncoder;
};

interface TextEncoderCommon {
    /**
     * Returns "utf-8".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEncoder/encoding)
     */
    readonly encoding: string;
}

/**
 * The **`TextEncoderStream`** interface of the Encoding API converts a stream of strings into bytes in the UTF-8 encoding. It is the streaming equivalent of TextEncoder. It implements the same shape as a TransformStream, allowing it to be used in ReadableStream.pipeThrough() and similar methods.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEncoderStream)
 */
interface TextEncoderStream extends GenericTransformStream, TextEncoderCommon {
    /** The **`readable`** read-only property of the TextEncoderStream interface returns a ReadableStream that emits encoded binary data as Uint8Array chunks. */
    readonly readable: ReadableStream<Uint8Array<ArrayBuffer>>;
    /** The **`writable`** read-only property of the TextEncoderStream interface returns a WritableStream that accepts strings to be encoded into binary data. */
    readonly writable: WritableStream<string>;
}

declare var TextEncoderStream: {
    prototype: TextEncoderStream;
    new(): TextEncoderStream;
};

/**
 * The **`TextEvent`** interface is a legacy UI event interface for reporting changes to text UI elements.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEvent)
 */
interface TextEvent extends UIEvent {
    /**
     * The **`data`** read-only property of the TextEvent interface returns the last character added to the input element.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEvent/data)
     */
    readonly data: string;
    /**
     * The **`initTextEvent`**Event() method of the TextEvent interface initializes the value of a TextEvent after it has been created.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextEvent/initTextEvent)
     */
    initTextEvent(type: string, bubbles?: boolean, cancelable?: boolean, view?: Window | null, data?: string): void;
}

/** @deprecated */
declare var TextEvent: {
    prototype: TextEvent;
    new(): TextEvent;
};

/**
 * The **`TextMetrics`** interface represents the dimensions of a piece of text in the canvas; a TextMetrics instance can be retrieved using the CanvasRenderingContext2D.measureText() method.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics)
 */
interface TextMetrics {
    /**
     * The read-only **`actualBoundingBoxAscent`** property of the TextMetrics interface is a double giving the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline attribute to the top of the bounding rectangle used to render the text, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/actualBoundingBoxAscent)
     */
    readonly actualBoundingBoxAscent: number;
    /**
     * The read-only **`actualBoundingBoxDescent`** property of the TextMetrics interface is a double giving the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline attribute to the bottom of the bounding rectangle used to render the text, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/actualBoundingBoxDescent)
     */
    readonly actualBoundingBoxDescent: number;
    /**
     * The read-only **`actualBoundingBoxLeft`** property of the TextMetrics interface is a double giving the distance parallel to the baseline from the alignment point given by the CanvasRenderingContext2D.textAlign property to the left side of the bounding rectangle of the given text, in CSS pixels; positive numbers indicating a distance going left from the given alignment point.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/actualBoundingBoxLeft)
     */
    readonly actualBoundingBoxLeft: number;
    /**
     * The read-only **`actualBoundingBoxRight`** property of the TextMetrics interface is a double giving the distance parallel to the baseline from the alignment point given by the CanvasRenderingContext2D.textAlign property to the right side of the bounding rectangle of the given text, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/actualBoundingBoxRight)
     */
    readonly actualBoundingBoxRight: number;
    /**
     * The read-only **`alphabeticBaseline`** property of the TextMetrics interface is a double giving the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline property to the alphabetic baseline of the line box, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/alphabeticBaseline)
     */
    readonly alphabeticBaseline: number;
    /**
     * The read-only **`emHeightAscent`** property of the TextMetrics interface returns the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline property to the top of the em square in the line box, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/emHeightAscent)
     */
    readonly emHeightAscent: number;
    /**
     * The read-only **`emHeightDescent`** property of the TextMetrics interface returns the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline property to the bottom of the em square in the line box, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/emHeightDescent)
     */
    readonly emHeightDescent: number;
    /**
     * The read-only **`fontBoundingBoxAscent`** property of the TextMetrics interface returns the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline attribute, to the top of the highest bounding rectangle of all the fonts used to render the text, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/fontBoundingBoxAscent)
     */
    readonly fontBoundingBoxAscent: number;
    /**
     * The read-only **`fontBoundingBoxDescent`** property of the TextMetrics interface returns the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline attribute to the bottom of the bounding rectangle of all the fonts used to render the text, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/fontBoundingBoxDescent)
     */
    readonly fontBoundingBoxDescent: number;
    /**
     * The read-only **`hangingBaseline`** property of the TextMetrics interface is a double giving the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline property to the hanging baseline of the line box, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/hangingBaseline)
     */
    readonly hangingBaseline: number;
    /**
     * The read-only **`ideographicBaseline`** property of the TextMetrics interface is a double giving the distance from the horizontal line indicated by the CanvasRenderingContext2D.textBaseline property to the ideographic baseline of the line box, in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/ideographicBaseline)
     */
    readonly ideographicBaseline: number;
    /**
     * The read-only **`width`** property of the TextMetrics interface contains the text's advance width (the width of that inline box) in CSS pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextMetrics/width)
     */
    readonly width: number;
}

declare var TextMetrics: {
    prototype: TextMetrics;
    new(): TextMetrics;
};

interface TextTrackEventMap {
    "cuechange": Event;
}

/**
 * The **`TextTrack`** interface of the WebVTT API represents a text track associated with a media element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack)
 */
interface TextTrack extends EventTarget {
    /**
     * The **`activeCues`** read-only property of the TextTrack interface returns a TextTrackCueList object listing the currently active cues.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/activeCues)
     */
    readonly activeCues: TextTrackCueList | null;
    /**
     * The **`cues`** read-only property of the TextTrack interface returns a TextTrackCueList object containing all of the track's cues.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/cues)
     */
    readonly cues: TextTrackCueList | null;
    /**
     * The **`id`** read-only property of the TextTrack interface returns the ID of the track if it has one.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/id)
     */
    readonly id: string;
    /**
     * The **`inBandMetadataTrackDispatchType`** read-only property of the TextTrack interface returns the text track's in-band metadata dispatch type of the text track represented by the TextTrack object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/inBandMetadataTrackDispatchType)
     */
    readonly inBandMetadataTrackDispatchType: string;
    /**
     * The **`kind`** read-only property of the TextTrack interface returns the kind of text track this object represents. This decides how the track will be handled by a user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/kind)
     */
    readonly kind: TextTrackKind;
    /**
     * The **`label`** read-only property of the TextTrack interface returns a human-readable label for the text track, if it is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/label)
     */
    readonly label: string;
    /**
     * The **`language`** read-only property of the TextTrack interface returns the language of the text track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/language)
     */
    readonly language: string;
    /**
     * The TextTrack interface's **`mode`** property is a string specifying and controlling the text track's mode: disabled, hidden, or showing. You can read this value to determine the current mode, and you can change this value to switch modes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/mode)
     */
    mode: TextTrackMode;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/cuechange_event) */
    oncuechange: ((this: TextTrack, ev: Event) => any) | null;
    /**
     * The **`addCue()`** method of the TextTrack interface adds a new cue to the list of cues.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/addCue)
     */
    addCue(cue: TextTrackCue): void;
    /**
     * The **`removeCue()`** method of the TextTrack interface removes a cue from the list of cues.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrack/removeCue)
     */
    removeCue(cue: TextTrackCue): void;
    addEventListener<K extends keyof TextTrackEventMap>(type: K, listener: (this: TextTrack, ev: TextTrackEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof TextTrackEventMap>(type: K, listener: (this: TextTrack, ev: TextTrackEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var TextTrack: {
    prototype: TextTrack;
    new(): TextTrack;
};

interface TextTrackCueEventMap {
    "enter": Event;
    "exit": Event;
}

/**
 * The **`TextTrackCue`** interface of the WebVTT API is the abstract base class for the various derived cue types, such as VTTCue and DataCue; you will work with these derived types rather than the base class.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue)
 */
interface TextTrackCue extends EventTarget {
    /**
     * The **`endTime`** property of the TextTrackCue interface returns and sets the end time of the cue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/endTime)
     */
    endTime: number;
    /**
     * The **`id`** property of the TextTrackCue interface returns and sets the identifier for this cue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/id)
     */
    id: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/enter_event) */
    onenter: ((this: TextTrackCue, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/exit_event) */
    onexit: ((this: TextTrackCue, ev: Event) => any) | null;
    /**
     * The **`pauseOnExit`** property of the TextTrackCue interface returns or sets the flag indicating whether playback of the media should pause when the end of the range to which this cue applies is reached.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/pauseOnExit)
     */
    pauseOnExit: boolean;
    /**
     * The **`startTime`** property of the TextTrackCue interface returns and sets the start time of the cue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/startTime)
     */
    startTime: number;
    /**
     * The **`track`** read-only property of the TextTrackCue interface returns the TextTrack object that this cue belongs to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCue/track)
     */
    readonly track: TextTrack | null;
    addEventListener<K extends keyof TextTrackCueEventMap>(type: K, listener: (this: TextTrackCue, ev: TextTrackCueEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof TextTrackCueEventMap>(type: K, listener: (this: TextTrackCue, ev: TextTrackCueEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var TextTrackCue: {
    prototype: TextTrackCue;
    new(): TextTrackCue;
};

/**
 * The **`TextTrackCueList`** interface of the WebVTT API is an array-like object that represents a dynamically updating list of TextTrackCue objects.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCueList)
 */
interface TextTrackCueList {
    /**
     * The **`length`** read-only property of the TextTrackCueList interface returns the number of cues in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCueList/length)
     */
    readonly length: number;
    /**
     * The **`getCueById()`** method of the TextTrackCueList interface returns the first VTTCue in the list represented by the TextTrackCueList object whose identifier matches the value of id.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackCueList/getCueById)
     */
    getCueById(id: string): TextTrackCue | null;
    [index: number]: TextTrackCue;
}

declare var TextTrackCueList: {
    prototype: TextTrackCueList;
    new(): TextTrackCueList;
};

interface TextTrackListEventMap {
    "addtrack": TrackEvent;
    "change": Event;
    "removetrack": TrackEvent;
}

/**
 * The **`TextTrackList`** interface is used to represent a list of the text tracks defined for the associated video or audio element, with each track represented by a separate TextTrack object in the list.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackList)
 */
interface TextTrackList extends EventTarget {
    /**
     * The read-only TextTrackList property **`length`** returns the number of entries in the TextTrackList, each of which is a TextTrack representing one track in the media element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackList/length)
     */
    readonly length: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackList/addtrack_event) */
    onaddtrack: ((this: TextTrackList, ev: TrackEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackList/change_event) */
    onchange: ((this: TextTrackList, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackList/removetrack_event) */
    onremovetrack: ((this: TextTrackList, ev: TrackEvent) => any) | null;
    /**
     * The TextTrackList method **`getTrackById()`** returns the first TextTrack object from the track list whose id matches the specified string. This lets you find a specified track if you know its ID string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TextTrackList/getTrackById)
     */
    getTrackById(id: string): TextTrack | null;
    addEventListener<K extends keyof TextTrackListEventMap>(type: K, listener: (this: TextTrackList, ev: TextTrackListEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof TextTrackListEventMap>(type: K, listener: (this: TextTrackList, ev: TextTrackListEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
    [index: number]: TextTrack;
}

declare var TextTrackList: {
    prototype: TextTrackList;
    new(): TextTrackList;
};

/**
 * When loading a media resource for use by an <audio> or <video> element, the **`TimeRanges`** interface is used for representing the time ranges of the media resource that have been buffered, the time ranges that have been played, and the time ranges that are seekable.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TimeRanges)
 */
interface TimeRanges {
    /**
     * The **`TimeRanges.length`** read-only property returns the number of ranges in the object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TimeRanges/length)
     */
    readonly length: number;
    /**
     * The **`end()`** method of the TimeRanges interface returns the time offset (in seconds) at which a specified time range ends.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TimeRanges/end)
     */
    end(index: number): number;
    /**
     * The **`start()`** method of the TimeRanges interface returns the time offset (in seconds) at which a specified time range begins.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TimeRanges/start)
     */
    start(index: number): number;
}

declare var TimeRanges: {
    prototype: TimeRanges;
    new(): TimeRanges;
};

/**
 * The **`ToggleEvent`** interface represents an event that fires when a popover element is toggled between being shown and hidden.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ToggleEvent)
 */
interface ToggleEvent extends Event {
    /**
     * The **`newState`** read-only property of the ToggleEvent interface is a string representing the state the element is transitioning to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ToggleEvent/newState)
     */
    readonly newState: string;
    /**
     * The **`oldState`** read-only property of the ToggleEvent interface is a string representing the state the element is transitioning from.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ToggleEvent/oldState)
     */
    readonly oldState: string;
    /**
     * The **`source`** read-only property of the ToggleEvent interface is an Element object instance representing the HTML popover control element that initiated the toggle.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ToggleEvent/source)
     */
    readonly source: Element | null;
}

declare var ToggleEvent: {
    prototype: ToggleEvent;
    new(type: string, eventInitDict?: ToggleEventInit): ToggleEvent;
};

/**
 * The **`Touch`** interface represents a single contact point on a touch-sensitive device. The contact point is commonly a finger or stylus and the device may be a touchscreen or trackpad.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch)
 */
interface Touch {
    /**
     * The **`Touch.clientX`** read-only property returns the X coordinate of the touch point relative to the viewport, not including any scroll offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/clientX)
     */
    readonly clientX: number;
    /**
     * The **`Touch.clientY`** read-only property returns the Y coordinate of the touch point relative to the browser's viewport, not including any scroll offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/clientY)
     */
    readonly clientY: number;
    /**
     * The **`Touch.force`** read-only property returns the amount of pressure the user is applying to the touch surface for a Touch point.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/force)
     */
    readonly force: number;
    /**
     * The **`Touch.identifier`** returns a value uniquely identifying this point of contact with the touch surface. This value remains consistent for every event involving this finger's (or stylus's) movement on the surface until it is lifted off the surface.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/identifier)
     */
    readonly identifier: number;
    /**
     * The **`Touch.pageX`** read-only property returns the X coordinate of the touch point relative to the viewport, including any scroll offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/pageX)
     */
    readonly pageX: number;
    /**
     * The **`Touch.pageY`** read-only property returns the Y coordinate of the touch point relative to the viewport, including any scroll offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/pageY)
     */
    readonly pageY: number;
    /**
     * The **`radiusX`** read-only property of the Touch interface returns the X radius of the ellipse that most closely circumscribes the area of contact with the touch surface. The value is in CSS pixels of the same scale as Touch.screenX.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/radiusX)
     */
    readonly radiusX: number;
    /**
     * The **`radiusY`** read-only property of the Touch interface returns the Y radius of the ellipse that most closely circumscribes the area of contact with the touch surface. The value is in CSS pixels of the same scale as Touch.screenX.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/radiusY)
     */
    readonly radiusY: number;
    /**
     * The **`rotationAngle`** read-only property of the Touch interface returns the rotation angle, in degrees, of the contact area ellipse defined by Touch.radiusX and Touch.radiusY. The value may be between 0 and 90. Together, these three values describe an ellipse that approximates the size and shape of the area of contact between the user and the screen. This may be a relatively large ellipse representing the contact between a fingertip and the screen or a small area representing the tip of a stylus, for example.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/rotationAngle)
     */
    readonly rotationAngle: number;
    /**
     * Returns the X coordinate of the touch point relative to the screen, not including any scroll offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/screenX)
     */
    readonly screenX: number;
    /**
     * Returns the Y coordinate of the touch point relative to the screen, not including any scroll offset.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/screenY)
     */
    readonly screenY: number;
    /**
     * The read-only **`target`** property of the Touch interface returns the (EventTarget) on which the touch contact started when it was first placed on the surface, even if the touch point has since moved outside the interactive area of that element or even been removed from the document. Note that if the target element is removed from the document, events will still be targeted at it, and hence won't necessarily bubble up to the window or document anymore. If there is any risk of an element being removed while it is being touched, the best practice is to attach the touch listeners directly to the target.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Touch/target)
     */
    readonly target: EventTarget;
}

declare var Touch: {
    prototype: Touch;
    new(touchInitDict: TouchInit): Touch;
};

/**
 * The **`TouchEvent`** interface represents an UIEvent which is sent when the state of contacts with a touch-sensitive surface changes. This surface can be a touch screen or trackpad, for example. The event can describe one or more points of contact with the screen and includes support for detecting movement, addition and removal of contact points, and so forth.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent)
 */
interface TouchEvent extends UIEvent {
    /**
     * The read-only **`altKey`** property of the TouchEvent interface returns a boolean value indicating whether or not the alt (Alternate) key is enabled when the touch event is created. If the alt key is enabled, the attribute's value is true. Otherwise, it is false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/altKey)
     */
    readonly altKey: boolean;
    /**
     * The **`changedTouches`** read-only property is a TouchList whose touch points (Touch objects) varies depending on the event type, as follows:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/changedTouches)
     */
    readonly changedTouches: TouchList;
    /**
     * The read-only **`ctrlKey`** property of the TouchEvent interface returns a boolean value indicating whether the control (Control) key is enabled when the touch event is created. If this key is enabled, the attribute's value is true. Otherwise, it is false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/ctrlKey)
     */
    readonly ctrlKey: boolean;
    /**
     * The read-only **`metaKey`** property of the TouchEvent interface returns a boolean value indicating whether or not the Meta key is enabled when the touch event is created. If this key is enabled, the attribute's value is true. Otherwise, it is false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/metaKey)
     */
    readonly metaKey: boolean;
    /**
     * The read-only **`shiftKey`** property of the TouchEvent interface returns a boolean value indicating whether or not the shift key is enabled when the touch event is created. If this key is enabled, the attribute's value is true. Otherwise, it is false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/shiftKey)
     */
    readonly shiftKey: boolean;
    /**
     * The **`targetTouches`** read-only property is a TouchList listing all the Touch objects for touch points that are still in contact with the touch surface and whose touchstart event occurred inside the same target element as the current target element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/targetTouches)
     */
    readonly targetTouches: TouchList;
    /**
     * **`touches`** is a read-only TouchList listing all the Touch objects for touch points that are currently in contact with the touch surface, regardless of whether or not they've changed or what their target element was at touchstart time.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchEvent/touches)
     */
    readonly touches: TouchList;
}

declare var TouchEvent: {
    prototype: TouchEvent;
    new(type: string, eventInitDict?: TouchEventInit): TouchEvent;
};

/**
 * The **`TouchList`** interface represents a list of contact points on a touch surface. For example, if the user has three fingers on the touch surface (such as a screen or trackpad), the corresponding TouchList object would have one Touch object for each finger, for a total of three entries.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchList)
 */
interface TouchList {
    /**
     * The **`length`** read-only property indicates the number of items (touch points) in a given TouchList.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchList/length)
     */
    readonly length: number;
    /**
     * The **`item()`** method returns the Touch object at the specified index in the TouchList.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TouchList/item)
     */
    item(index: number): Touch | null;
    [index: number]: Touch;
}

declare var TouchList: {
    prototype: TouchList;
    new(): TouchList;
};

/**
 * The **`TrackEvent`** interface of the HTML DOM API is used for events which represent changes to a set of available tracks on an HTML media element; these events are addtrack and removetrack.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TrackEvent)
 */
interface TrackEvent extends Event {
    /**
     * The read-only **`track`** property of the TrackEvent interface specifies the media track object to which the event applies.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TrackEvent/track)
     */
    readonly track: TextTrack | null;
}

declare var TrackEvent: {
    prototype: TrackEvent;
    new(type: string, eventInitDict?: TrackEventInit): TrackEvent;
};

/**
 * The **`TransformStream`** interface of the Streams API represents a concrete implementation of the pipe chain transform stream concept.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStream)
 */
interface TransformStream<I = any, O = any> {
    /**
     * The **`readable`** read-only property of the TransformStream interface returns the ReadableStream instance controlled by this TransformStream. This stream emits the transformed output data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStream/readable)
     */
    readonly readable: ReadableStream<O>;
    /**
     * The **`writable`** read-only property of the TransformStream interface returns the WritableStream instance controlled by this TransformStream. This stream accepts input data that will be transformed and emitted to the readable stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStream/writable)
     */
    readonly writable: WritableStream<I>;
}

declare var TransformStream: {
    prototype: TransformStream;
    new<I = any, O = any>(transformer?: Transformer<I, O>, writableStrategy?: QueuingStrategy<I>, readableStrategy?: QueuingStrategy<O>): TransformStream<I, O>;
};

/**
 * The **`TransformStreamDefaultController`** interface of the Streams API provides methods to manipulate the associated ReadableStream and WritableStream.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStreamDefaultController)
 */
interface TransformStreamDefaultController<O = any> {
    /**
     * The **`desiredSize`** read-only property of the TransformStreamDefaultController interface returns the desired size to fill the queue of the associated ReadableStream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStreamDefaultController/desiredSize)
     */
    readonly desiredSize: number | null;
    /**
     * The **`enqueue()`** method of the TransformStreamDefaultController interface enqueues the given chunk in the readable side of the stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStreamDefaultController/enqueue)
     */
    enqueue(chunk?: O): void;
    /**
     * The **`error()`** method of the TransformStreamDefaultController interface errors both sides of the stream. Any further interactions with it will fail with the given error message, and any chunks in the queue will be discarded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStreamDefaultController/error)
     */
    error(reason?: any): void;
    /**
     * The **`terminate()`** method of the TransformStreamDefaultController interface closes the readable side and errors the writable side of the stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransformStreamDefaultController/terminate)
     */
    terminate(): void;
}

declare var TransformStreamDefaultController: {
    prototype: TransformStreamDefaultController;
    new(): TransformStreamDefaultController;
};

/**
 * The **`TransitionEvent`** interface represents events providing information related to transitions.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransitionEvent)
 */
interface TransitionEvent extends Event {
    /**
     * The **`TransitionEvent.elapsedTime`** read-only property is a float giving the amount of time the animation has been running, in seconds, when this event fired. This value is not affected by the transition-delay property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransitionEvent/elapsedTime)
     */
    readonly elapsedTime: number;
    /**
     * The **`propertyName`** read-only property of TransitionEvent objects is a string containing the name of the CSS property associated with the transition.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransitionEvent/propertyName)
     */
    readonly propertyName: string;
    /**
     * The **`TransitionEvent.pseudoElement`** read-only property is a string, starting with '::', containing the name of the pseudo-element the animation runs on. If the transition doesn't run on a pseudo-element but on the element, an empty string: "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TransitionEvent/pseudoElement)
     */
    readonly pseudoElement: string;
}

declare var TransitionEvent: {
    prototype: TransitionEvent;
    new(type: string, transitionEventInitDict?: TransitionEventInit): TransitionEvent;
};

/**
 * The **`TreeWalker`** object represents the nodes of a document subtree and a position within them.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker)
 */
interface TreeWalker {
    /**
     * The **`TreeWalker.currentNode`** property represents the Node which the TreeWalker is currently pointing at.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/currentNode)
     */
    currentNode: Node;
    /**
     * The **`TreeWalker.filter`** read-only property returns the NodeFilter associated with the TreeWalker.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/filter)
     */
    readonly filter: NodeFilter | null;
    /**
     * The **`TreeWalker.root`** read-only property returns the root Node that the TreeWalker traverses.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/root)
     */
    readonly root: Node;
    /**
     * The **`TreeWalker.whatToShow`** read-only property returns a bitmask that indicates the types of nodes to show. Non-matching nodes are skipped, but their children may be included, if relevant.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/whatToShow)
     */
    readonly whatToShow: number;
    /**
     * The **`TreeWalker.firstChild()`** method moves the current Node to the first visible child of the current node, and returns the found child. If no such child exists, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/firstChild)
     */
    firstChild(): Node | null;
    /**
     * The **`TreeWalker.lastChild()`** method moves the current Node to the last visible child of the current node, and returns the found child. If no such child exists, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/lastChild)
     */
    lastChild(): Node | null;
    /**
     * The **`TreeWalker.nextNode()`** method moves the current Node to the next visible node in the document order, and returns the found node. If no such node exists, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/nextNode)
     */
    nextNode(): Node | null;
    /**
     * The **`TreeWalker.nextSibling()`** method moves the current Node to its next sibling, if any, and returns the found sibling. If there is no such node, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/nextSibling)
     */
    nextSibling(): Node | null;
    /**
     * The **`TreeWalker.parentNode()`** method moves the current Node to the first visible ancestor node in the document order, and returns the found node. If no such node exists, or if it is above the TreeWalker's root node, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/parentNode)
     */
    parentNode(): Node | null;
    /**
     * The **`TreeWalker.previousNode()`** method moves the current Node to the previous visible node in the document order, and returns the found node. If no such node exists, or if it is before that the root node defined at the object construction, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/previousNode)
     */
    previousNode(): Node | null;
    /**
     * The **`TreeWalker.previousSibling()`** method moves the current Node to its previous sibling, if any, and returns the found sibling. If there is no such node, it returns null and the current node is not changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/TreeWalker/previousSibling)
     */
    previousSibling(): Node | null;
}

declare var TreeWalker: {
    prototype: TreeWalker;
    new(): TreeWalker;
};

/**
 * The **`UIEvent`** interface represents simple user interface events. It is part of the UI Events API, which includes various event types and interfaces related to user interactions.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UIEvent)
 */
interface UIEvent extends Event {
    /**
     * The **`UIEvent.detail`** read-only property, when non-zero, provides the current (or next, depending on the event) click count.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UIEvent/detail)
     */
    readonly detail: number;
    /**
     * The **`UIEvent.view`** read-only property returns the WindowProxy object from which the event was generated. In browsers, this is the Window object the event happened in.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UIEvent/view)
     */
    readonly view: Window | null;
    /**
     * The **`UIEvent.which`** read-only property of the UIEvent interface returns a number that indicates which button was pressed on the mouse, or the numeric keyCode or the character code (charCode) of the key pressed on the keyboard.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UIEvent/which)
     */
    readonly which: number;
    /**
     * The **`UIEvent.initUIEvent()`** method initializes a UI event once it's been created.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UIEvent/initUIEvent)
     */
    initUIEvent(typeArg: string, bubblesArg?: boolean, cancelableArg?: boolean, viewArg?: Window | null, detailArg?: number): void;
}

declare var UIEvent: {
    prototype: UIEvent;
    new(type: string, eventInitDict?: UIEventInit): UIEvent;
};

/**
 * The **`URL`** interface is used to parse, construct, normalize, and encode URLs. It works by providing properties which allow you to easily read and modify the components of a URL.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL)
 */
interface URL {
    /**
     * The **`hash`** property of the URL interface is a string containing a "#" followed by the fragment identifier of the URL. If the URL does not have a fragment identifier, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/hash)
     */
    hash: string;
    /**
     * The **`host`** property of the URL interface is a string containing the host, which is the hostname, and then, if the port of the URL is nonempty, a ":", followed by the port of the URL. If the URL does not have a hostname, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/host)
     */
    host: string;
    /**
     * The **`hostname`** property of the URL interface is a string containing either the domain name or IP address of the URL. If the URL does not have a hostname, this property contains an empty string, "". IPv4 and IPv6 addresses are normalized, such as stripping leading zeros, and domain names are converted to IDN.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/hostname)
     */
    hostname: string;
    /**
     * The **`href`** property of the URL interface is a string containing the whole URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/href)
     */
    href: string;
    toString(): string;
    /**
     * The **`origin`** read-only property of the URL interface returns a string containing the Unicode serialization of the origin of the represented URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/origin)
     */
    readonly origin: string;
    /**
     * The **`password`** property of the URL interface is a string containing the password component of the URL. If the URL does not have a password, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/password)
     */
    password: string;
    /**
     * The **`pathname`** property of the URL interface represents a location in a hierarchical structure. It is a string constructed from a list of path segments, each of which is prefixed by a / character.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/pathname)
     */
    pathname: string;
    /**
     * The **`port`** property of the URL interface is a string containing the port number of the URL. If the port is the default for the protocol (80 for ws: and http:, 443 for wss: and https:, and 21 for ftp:), this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/port)
     */
    port: string;
    /**
     * The **`protocol`** property of the URL interface is a string containing the protocol or scheme of the URL, including the final ":".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/protocol)
     */
    protocol: string;
    /**
     * The **`search`** property of the URL interface is a search string, also called a query string, that is a string containing a "?" followed by the parameters of the URL. If the URL does not have a search query, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/search)
     */
    search: string;
    /**
     * The **`searchParams`** read-only property of the URL interface returns a URLSearchParams object allowing access to the GET decoded query arguments contained in the URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/searchParams)
     */
    readonly searchParams: URLSearchParams;
    /**
     * The **`username`** property of the URL interface is a string containing the username component of the URL. If the URL does not have a username, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/username)
     */
    username: string;
    /**
     * The **`toJSON()`** method of the URL interface returns a string containing a serialized version of the URL, although in practice it seems to have the same effect as URL.toString().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/toJSON)
     */
    toJSON(): string;
}

declare var URL: {
    prototype: URL;
    new(url: string | URL, base?: string | URL): URL;
    /**
     * The **`URL.canParse()`** static method of the URL interface returns a boolean indicating whether or not an absolute URL, or a relative URL combined with a base URL, are parsable and valid.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/canParse_static)
     */
    canParse(url: string | URL, base?: string | URL): boolean;
    /**
     * The **`createObjectURL()`** static method of the URL interface creates a string containing a blob URL pointing to the object given in the parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/createObjectURL_static)
     */
    createObjectURL(obj: Blob | MediaSource): string;
    /**
     * The **`URL.parse()`** static method of the URL interface returns a newly created URL object representing the URL defined by the parameters.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/parse_static)
     */
    parse(url: string | URL, base?: string | URL): URL | null;
    /**
     * The **`revokeObjectURL()`** static method of the URL interface releases an existing object URL which was previously created by calling URL.createObjectURL().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URL/revokeObjectURL_static)
     */
    revokeObjectURL(url: string): void;
};

type webkitURL = URL;
declare var webkitURL: typeof URL;

/**
 * The **`URLPattern`** interface of the URL Pattern API matches URLs or parts of URLs against a pattern. The pattern can contain capturing groups that extract parts of the matched URL.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern)
 */
interface URLPattern {
    /**
     * The **`hasRegExpGroups`** read-only property of the URLPattern interface is a boolean indicating whether or not any of the URLPattern components contain regular expression capturing groups.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/hasRegExpGroups)
     */
    readonly hasRegExpGroups: boolean;
    /**
     * The **`hash`** read-only property of the URLPattern interface is a string containing the pattern used to match the fragment part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/hash)
     */
    readonly hash: string;
    /**
     * The **`hostname`** read-only property of the URLPattern interface is a string containing the pattern used to match the hostname part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/hostname)
     */
    readonly hostname: string;
    /**
     * The **`password`** read-only property of the URLPattern interface is a string containing the pattern used to match the password part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/password)
     */
    readonly password: string;
    /**
     * The **`pathname`** read-only property of the URLPattern interface is a string containing the pattern used to match the pathname part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/pathname)
     */
    readonly pathname: string;
    /**
     * The **`port`** read-only property of the URLPattern interface is a string containing the pattern used to match the port part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/port)
     */
    readonly port: string;
    /**
     * The **`protocol`** read-only property of the URLPattern interface is a string containing the pattern used to match the protocol part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/protocol)
     */
    readonly protocol: string;
    /**
     * The **`search`** read-only property of the URLPattern interface is a string containing the pattern used to match the search part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/search)
     */
    readonly search: string;
    /**
     * The **`username`** read-only property of the URLPattern interface is a string containing the pattern used to match the username part of a URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/username)
     */
    readonly username: string;
    /**
     * The **`exec()`** method of the URLPattern interface takes a URL or object of URL parts, and returns either an object containing the results of matching the URL to the pattern, or null if the URL does not match the pattern.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/exec)
     */
    exec(input?: URLPatternInput, baseURL?: string | URL): URLPatternResult | null;
    /**
     * The **`test()`** method of the URLPattern interface takes a URL string or object of URL parts, and returns a boolean indicating if the given input matches the current pattern.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLPattern/test)
     */
    test(input?: URLPatternInput, baseURL?: string | URL): boolean;
}

declare var URLPattern: {
    prototype: URLPattern;
    new(input: URLPatternInput, baseURL: string | URL, options?: URLPatternOptions): URLPattern;
    new(input?: URLPatternInput, options?: URLPatternOptions): URLPattern;
};

/**
 * The **`URLSearchParams`** interface defines utility methods to work with the query string of a URL.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams)
 */
interface URLSearchParams {
    /**
     * The **`size`** read-only property of the URLSearchParams interface indicates the total number of search parameter entries.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/size)
     */
    readonly size: number;
    /**
     * The **`append()`** method of the URLSearchParams interface appends a specified key/value pair as a new search parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/append)
     */
    append(name: string, value: string): void;
    /**
     * The **`delete()`** method of the URLSearchParams interface deletes specified parameters and their associated value(s) from the list of all search parameters.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/delete)
     */
    delete(name: string, value?: string): void;
    /**
     * The **`get()`** method of the URLSearchParams interface returns the first value associated to the given search parameter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/get)
     */
    get(name: string): string | null;
    /**
     * The **`getAll()`** method of the URLSearchParams interface returns all the values associated with a given search parameter as an array.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/getAll)
     */
    getAll(name: string): string[];
    /**
     * The **`has()`** method of the URLSearchParams interface returns a boolean value that indicates whether the specified parameter is in the search parameters.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/has)
     */
    has(name: string, value?: string): boolean;
    /**
     * The **`set()`** method of the URLSearchParams interface sets the value associated with a given search parameter to the given value. If there were several matching values, this method deletes the others. If the search parameter doesn't exist, this method creates it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/set)
     */
    set(name: string, value: string): void;
    /**
     * The **`URLSearchParams.sort()`** method sorts all key/value pairs contained in this object in place and returns undefined. Key/value pairs are sorted by the values of the UTF-16 code units of the keys. This method uses a stable sorting algorithm (i.e., the relative order between key/value pairs with equal keys will be preserved).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/URLSearchParams/sort)
     */
    sort(): void;
    toString(): string;
    forEach(callbackfn: (value: string, key: string, parent: URLSearchParams) => void, thisArg?: any): void;
}

declare var URLSearchParams: {
    prototype: URLSearchParams;
    new(init?: string[][] | Record<string, string> | string | URLSearchParams): URLSearchParams;
};

/**
 * The **`UserActivation`** interface provides information about whether a user is currently interacting with the page, or has completed an interaction since page load.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UserActivation)
 */
interface UserActivation {
    /**
     * The read-only **`hasBeenActive`** property of the UserActivation interface indicates whether the current window has sticky user activation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UserActivation/hasBeenActive)
     */
    readonly hasBeenActive: boolean;
    /**
     * The read-only **`isActive`** property of the UserActivation interface indicates whether the current window has transient user activation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/UserActivation/isActive)
     */
    readonly isActive: boolean;
}

declare var UserActivation: {
    prototype: UserActivation;
    new(): UserActivation;
};

/**
 * The **`VTTCue`** interface of the WebVTT API represents a cue that can be added to the text track associated with a particular video (or other media).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue)
 */
interface VTTCue extends TextTrackCue {
    /**
     * The **`align`** property of the VTTCue interface represents the alignment of all of the lines of text in the text box.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/align)
     */
    align: AlignSetting;
    /**
     * The **`line`** property of the VTTCue interface represents the cue line of this WebVTT cue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/line)
     */
    line: LineAndPositionSetting;
    /**
     * The **`lineAlign`** property of the VTTCue interface represents the alignment of this VTT cue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/lineAlign)
     */
    lineAlign: LineAlignSetting;
    /**
     * The **`position`** property of the VTTCue interface represents the indentation of the cue within the line.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/position)
     */
    position: LineAndPositionSetting;
    /**
     * The **`positionAlign`** property of the VTTCue interface is used to determine what VTTCue.position is anchored to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/positionAlign)
     */
    positionAlign: PositionAlignSetting;
    /**
     * The **`region`** property of the VTTCue interface returns and sets the VTTRegion that this cue belongs to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/region)
     */
    region: VTTRegion | null;
    /**
     * The **`size`** property of the VTTCue interface represents the size of the cue as a percentage of the video size.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/size)
     */
    size: number;
    /**
     * The **`snapToLines`** property of the VTTCue interface is a Boolean indicating if the VTTCue.line property is an integer number of lines, or a percentage of the video size.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/snapToLines)
     */
    snapToLines: boolean;
    /**
     * The **`text`** property of the VTTCue interface represents the text contents of the cue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/text)
     */
    text: string;
    /**
     * The **`vertical`** property of the VTTCue interface is a string representing the cue's writing direction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/vertical)
     */
    vertical: DirectionSetting;
    /**
     * The **`getCueAsHTML()`** method of the VTTCue interface returns a DocumentFragment containing the cue content.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTCue/getCueAsHTML)
     */
    getCueAsHTML(): DocumentFragment;
    addEventListener<K extends keyof TextTrackCueEventMap>(type: K, listener: (this: VTTCue, ev: TextTrackCueEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof TextTrackCueEventMap>(type: K, listener: (this: VTTCue, ev: TextTrackCueEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var VTTCue: {
    prototype: VTTCue;
    new(startTime: number, endTime: number, text: string): VTTCue;
};

/**
 * The **`VTTRegion`** interface of the WebVTT API describes a portion of the video to render a VTTCue onto.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VTTRegion)
 */
interface VTTRegion {
    id: string;
    lines: number;
    regionAnchorX: number;
    regionAnchorY: number;
    scroll: ScrollSetting;
    viewportAnchorX: number;
    viewportAnchorY: number;
    width: number;
}

declare var VTTRegion: {
    prototype: VTTRegion;
    new(): VTTRegion;
};

/**
 * The **`ValidityState`** interface represents the validity states that an element can be in, with respect to constraint validation. Together, they help explain why an element's value fails to validate, if it's not valid.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState)
 */
interface ValidityState {
    /**
     * The read-only **`badInput`** property of the ValidityState interface indicates if the user has provided input that the browser is unable to convert. For example, if you have a number input element whose content is a string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/badInput)
     */
    readonly badInput: boolean;
    /**
     * The read-only **`customError`** property of the ValidityState interface returns true if an element doesn't meet the validation required in the custom validity set by the element's setCustomValidity() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/customError)
     */
    readonly customError: boolean;
    /**
     * The read-only **`patternMismatch`** property of the ValidityState interface indicates if the value of an <input>, after having been edited by the user, does not conform to the constraints set by the element's pattern attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/patternMismatch)
     */
    readonly patternMismatch: boolean;
    /**
     * The read-only **`rangeOverflow`** property of the ValidityState interface indicates if the value of an <input>, after having been edited by the user, does not conform to the constraints set by the element's max attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/rangeOverflow)
     */
    readonly rangeOverflow: boolean;
    /**
     * The read-only **`rangeUnderflow`** property of the ValidityState interface indicates if the value of an <input>, after having been edited by the user, does not conform to the constraints set by the element's min attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/rangeUnderflow)
     */
    readonly rangeUnderflow: boolean;
    /**
     * The read-only **`stepMismatch`** property of the ValidityState interface indicates if the value of an <input>, after having been edited by the user, does not conform to the constraints set by the element's step attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/stepMismatch)
     */
    readonly stepMismatch: boolean;
    /**
     * The read-only **`tooLong`** property of the ValidityState interface indicates if the value of an <input> or <textarea>, after having been edited by the user, exceeds the maximum code-unit length established by the element's maxlength attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/tooLong)
     */
    readonly tooLong: boolean;
    /**
     * The read-only **`tooShort`** property of the ValidityState interface indicates if the value of an <input>, <button>, <select>, <output>, <fieldset> or <textarea>, after having been edited by the user, is less than the minimum code-unit length established by the element's minlength attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/tooShort)
     */
    readonly tooShort: boolean;
    /**
     * The read-only **`typeMismatch`** property of the ValidityState interface indicates if the value of an <input>, after having been edited by the user, does not conform to the constraints set by the element's type attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/typeMismatch)
     */
    readonly typeMismatch: boolean;
    /**
     * The read-only **`valid`** property of the ValidityState interface indicates if the value of an <input> element meets all its validation constraints, and is therefore considered to be valid.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/valid)
     */
    readonly valid: boolean;
    /**
     * The read-only **`valueMissing`** property of the ValidityState interface indicates if a required control, such as an <input>, <select>, or <textarea>, has an empty value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ValidityState/valueMissing)
     */
    readonly valueMissing: boolean;
}

declare var ValidityState: {
    prototype: ValidityState;
    new(): ValidityState;
};

/**
 * The **`VideoColorSpace`** interface of the WebCodecs API represents the color space of a video.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoColorSpace)
 */
interface VideoColorSpace {
    /**
     * The **`fullRange`** read-only property of the VideoColorSpace interface returns true if full-range color values are used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoColorSpace/fullRange)
     */
    readonly fullRange: boolean | null;
    /**
     * The **`matrix`** read-only property of the VideoColorSpace interface returns the matrix coefficient of the video. Matrix coefficients describe the relationship between sample component values and color coordinates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoColorSpace/matrix)
     */
    readonly matrix: VideoMatrixCoefficients | null;
    /**
     * The **`primaries`** read-only property of the VideoColorSpace interface returns the color gamut of the video.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoColorSpace/primaries)
     */
    readonly primaries: VideoColorPrimaries | null;
    /**
     * The **`transfer`** read-only property of the VideoColorSpace interface returns the opto-electronic transfer characteristics of the video.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoColorSpace/transfer)
     */
    readonly transfer: VideoTransferCharacteristics | null;
    /**
     * The **`toJSON()`** method of the VideoColorSpace interface is a serializer that returns a JSON representation of the VideoColorSpace object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoColorSpace/toJSON)
     */
    toJSON(): VideoColorSpaceInit;
}

declare var VideoColorSpace: {
    prototype: VideoColorSpace;
    new(init?: VideoColorSpaceInit): VideoColorSpace;
};

interface VideoDecoderEventMap {
    "dequeue": Event;
}

/**
 * The **`VideoDecoder`** interface of the WebCodecs API decodes chunks of video.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder)
 */
interface VideoDecoder extends EventTarget {
    /**
     * The **`decodeQueueSize`** read-only property of the VideoDecoder interface returns the number of pending decode requests in the queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/decodeQueueSize)
     */
    readonly decodeQueueSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/dequeue_event) */
    ondequeue: ((this: VideoDecoder, ev: Event) => any) | null;
    /**
     * The **`state`** property of the VideoDecoder interface returns the current state of the underlying codec.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/state)
     */
    readonly state: CodecState;
    /**
     * The **`close()`** method of the VideoDecoder interface ends all pending work and releases system resources.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/close)
     */
    close(): void;
    /**
     * The **`configure()`** method of the VideoDecoder interface enqueues a control message to configure the video decoder for decoding chunks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/configure)
     */
    configure(config: VideoDecoderConfig): void;
    /**
     * The **`decode()`** method of the VideoDecoder interface enqueues a control message to decode a given chunk of video.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/decode)
     */
    decode(chunk: EncodedVideoChunk): void;
    /**
     * The **`flush()`** method of the VideoDecoder interface returns a Promise that resolves once all pending messages in the queue have been completed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/flush)
     */
    flush(): Promise<void>;
    /**
     * The **`reset()`** method of the VideoDecoder interface resets all states including configuration, control messages in the control message queue, and all pending callbacks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/reset)
     */
    reset(): void;
    addEventListener<K extends keyof VideoDecoderEventMap>(type: K, listener: (this: VideoDecoder, ev: VideoDecoderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof VideoDecoderEventMap>(type: K, listener: (this: VideoDecoder, ev: VideoDecoderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var VideoDecoder: {
    prototype: VideoDecoder;
    new(init: VideoDecoderInit): VideoDecoder;
    /**
     * The **`isConfigSupported()`** static method of the VideoDecoder interface checks if the given config is supported (that is, if VideoDecoder objects can be successfully configured with the given config).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoDecoder/isConfigSupported_static)
     */
    isConfigSupported(config: VideoDecoderConfig): Promise<VideoDecoderSupport>;
};

interface VideoEncoderEventMap {
    "dequeue": Event;
}

/**
 * The **`VideoEncoder`** interface of the WebCodecs API encodes VideoFrame objects into EncodedVideoChunks.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder)
 */
interface VideoEncoder extends EventTarget {
    /**
     * The **`encodeQueueSize`** read-only property of the VideoEncoder interface returns the number of pending encode requests in the queue.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/encodeQueueSize)
     */
    readonly encodeQueueSize: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/dequeue_event) */
    ondequeue: ((this: VideoEncoder, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the VideoEncoder interface returns the current state of the underlying codec.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/state)
     */
    readonly state: CodecState;
    /**
     * The **`close()`** method of the VideoEncoder interface ends all pending work and releases system resources.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/close)
     */
    close(): void;
    /**
     * The **`configure()`** method of the VideoEncoder interface changes the state of the encoder to "configured" and asynchronously prepares the encoder to accept VideoEncoders for encoding with the specified parameters. If the encoder doesn't support the specified parameters or can't be initialized for other reasons an error will be reported via the error callback provided to the VideoEncoder constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/configure)
     */
    configure(config: VideoEncoderConfig): void;
    /**
     * The **`encode()`** method of the VideoEncoder interface asynchronously encodes a VideoFrame. Encoded data (EncodedVideoChunk) or an error will eventually be returned via the callbacks provided to the VideoEncoder constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/encode)
     */
    encode(frame: VideoFrame, options?: VideoEncoderEncodeOptions): void;
    /**
     * The **`flush()`** method of the VideoEncoder interface forces all pending encodes to complete.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/flush)
     */
    flush(): Promise<void>;
    /**
     * The **`reset()`** method of the VideoEncoder interface synchronously cancels all pending encodes and callbacks, frees all underlying resources and sets the state to "unconfigured". After calling reset(), configure() must be called before resuming encode() calls.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/reset)
     */
    reset(): void;
    addEventListener<K extends keyof VideoEncoderEventMap>(type: K, listener: (this: VideoEncoder, ev: VideoEncoderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof VideoEncoderEventMap>(type: K, listener: (this: VideoEncoder, ev: VideoEncoderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var VideoEncoder: {
    prototype: VideoEncoder;
    new(init: VideoEncoderInit): VideoEncoder;
    /**
     * The **`isConfigSupported()`** static method of the VideoEncoder interface checks if VideoEncoder can be successfully configured with the given config.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoEncoder/isConfigSupported_static)
     */
    isConfigSupported(config: VideoEncoderConfig): Promise<VideoEncoderSupport>;
};

/**
 * The **`VideoFrame`** interface of the Web Codecs API represents a frame of a video.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame)
 */
interface VideoFrame {
    /**
     * The **`codedHeight`** property of the VideoFrame interface returns the height of the VideoFrame in pixels, potentially including non-visible padding, and prior to considering potential ratio adjustments.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/codedHeight)
     */
    readonly codedHeight: number;
    /**
     * The **`codedRect`** property of the VideoFrame interface returns a DOMRectReadOnly with the width and height matching VideoFrame.codedWidth and VideoFrame.codedHeight.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/codedRect)
     */
    readonly codedRect: DOMRectReadOnly | null;
    /**
     * The **`codedWidth`** property of the VideoFrame interface returns the width of the VideoFrame in pixels, potentially including non-visible padding, and prior to considering potential ratio adjustments.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/codedWidth)
     */
    readonly codedWidth: number;
    /**
     * The **`colorSpace`** property of the VideoFrame interface returns a VideoColorSpace object representing the color space of the video.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/colorSpace)
     */
    readonly colorSpace: VideoColorSpace;
    /**
     * The **`displayHeight`** property of the VideoFrame interface returns the height of the VideoFrame after applying aspect ratio adjustments.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/displayHeight)
     */
    readonly displayHeight: number;
    /**
     * The **`displayWidth`** property of the VideoFrame interface returns the width of the VideoFrame after applying aspect ratio adjustments.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/displayWidth)
     */
    readonly displayWidth: number;
    /**
     * The **`duration`** property of the VideoFrame interface returns an integer indicating the duration of the video in microseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/duration)
     */
    readonly duration: number | null;
    /**
     * The **`format`** property of the VideoFrame interface returns the pixel format of the VideoFrame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/format)
     */
    readonly format: VideoPixelFormat | null;
    /**
     * The **`timestamp`** property of the VideoFrame interface returns an integer indicating the timestamp of the video in microseconds.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/timestamp)
     */
    readonly timestamp: number;
    /**
     * The **`visibleRect`** property of the VideoFrame interface returns a DOMRectReadOnly describing the visible rectangle of pixels for this VideoFrame.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/visibleRect)
     */
    readonly visibleRect: DOMRectReadOnly | null;
    /**
     * The **`allocationSize()`** method of the VideoFrame interface returns the number of bytes required to hold the video as filtered by options passed into the method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/allocationSize)
     */
    allocationSize(options?: VideoFrameCopyToOptions): number;
    /**
     * The **`clone()`** method of the VideoFrame interface creates a new VideoFrame object referencing the same media resource as the original.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/clone)
     */
    clone(): VideoFrame;
    /**
     * The **`close()`** method of the VideoFrame interface clears all states and releases the reference to the media resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/close)
     */
    close(): void;
    /**
     * The **`copyTo()`** method of the VideoFrame interface copies the contents of the VideoFrame to an ArrayBuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoFrame/copyTo)
     */
    copyTo(destination: AllowSharedBufferSource, options?: VideoFrameCopyToOptions): Promise<PlaneLayout[]>;
}

declare var VideoFrame: {
    prototype: VideoFrame;
    new(image: CanvasImageSource, init?: VideoFrameInit): VideoFrame;
    new(data: AllowSharedBufferSource, init: VideoFrameBufferInit): VideoFrame;
};

/**
 * A **`VideoPlaybackQuality`** object is returned by the HTMLVideoElement.getVideoPlaybackQuality() method and contains metrics that can be used to determine the playback quality of a video.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoPlaybackQuality)
 */
interface VideoPlaybackQuality {
    /**
     * The VideoPlaybackQuality interface's read-only **`corruptedVideoFrames`** property the number of corrupted video frames that have been received since the <video> element was last loaded or reloaded.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoPlaybackQuality/corruptedVideoFrames)
     */
    readonly corruptedVideoFrames: number;
    /**
     * The read-only **`creationTime`** property on the VideoPlaybackQuality interface reports the number of milliseconds since the browsing context was created this quality sample was recorded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoPlaybackQuality/creationTime)
     */
    readonly creationTime: DOMHighResTimeStamp;
    /**
     * The read-only **`droppedVideoFrames`** property of the VideoPlaybackQuality interface returns the number of video frames which have been dropped rather than being displayed since the last time the media was loaded into the HTMLVideoElement.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoPlaybackQuality/droppedVideoFrames)
     */
    readonly droppedVideoFrames: number;
    /**
     * The VideoPlaybackQuality interface's **`totalVideoFrames`** read-only property returns the total number of video frames that have been displayed or dropped since the media was loaded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VideoPlaybackQuality/totalVideoFrames)
     */
    readonly totalVideoFrames: number;
}

declare var VideoPlaybackQuality: {
    prototype: VideoPlaybackQuality;
    new(): VideoPlaybackQuality;
};

/**
 * The **`ViewTimeline`** interface of the Web Animations API represents a view progress timeline (see CSS scroll-driven animations for more details).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTimeline)
 */
interface ViewTimeline extends ScrollTimeline {
    /**
     * The **`endOffset`** read-only property of the ViewTimeline interface returns a CSSNumericValue representing the ending (100% progress) scroll position of the timeline as an offset from the start of the overflowing section of content in the scroller.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTimeline/endOffset)
     */
    readonly endOffset: CSSNumericValue;
    /**
     * The **`startOffset`** read-only property of the ViewTimeline interface returns a CSSNumericValue representing the starting (0% progress) scroll position of the timeline as an offset from the start of the overflowing section of content in the scroller.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTimeline/startOffset)
     */
    readonly startOffset: CSSNumericValue;
    /**
     * The **`subject`** read-only property of the ViewTimeline interface returns a reference to the subject element whose visibility within its nearest ancestor scrollable element (scroller) is driving the progress of the timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTimeline/subject)
     */
    readonly subject: Element;
}

declare var ViewTimeline: {
    prototype: ViewTimeline;
    new(options?: ViewTimelineOptions): ViewTimeline;
};

/**
 * The **`ViewTransition`** interface of the View Transition API represents an active view transition, and provides functionality to react to the transition reaching different states (e.g., ready to run the animation, or animation finished) or skip the transition altogether.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransition)
 */
interface ViewTransition {
    /**
     * The **`finished`** read-only property of the ViewTransition interface is a Promise that fulfills once the transition animation is finished, and the new page view is visible and interactive to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransition/finished)
     */
    readonly finished: Promise<void>;
    /**
     * The **`ready`** read-only property of the ViewTransition interface is a Promise that fulfills once the pseudo-element tree is created and the transition animation is about to start.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransition/ready)
     */
    readonly ready: Promise<void>;
    /**
     * The **`types`** read-only property of the ViewTransition interface is a ViewTransitionTypeSet that allows the types set on the view transition to be accessed and modified.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransition/types)
     */
    readonly types: ViewTransitionTypeSet;
    /**
     * The **`updateCallbackDone`** read-only property of the ViewTransition interface is a Promise that fulfills when the promise returned by the document.startViewTransition() method's callback fulfills, or rejects when it rejects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransition/updateCallbackDone)
     */
    readonly updateCallbackDone: Promise<void>;
    /**
     * The **`skipTransition()`** method of the ViewTransition interface skips the animation part of the view transition, but doesn't skip running the associated view update.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransition/skipTransition)
     */
    skipTransition(): void;
}

declare var ViewTransition: {
    prototype: ViewTransition;
    new(): ViewTransition;
};

/**
 * The **`ViewTransitionTypeSet`** interface of the View Transition API is a set-like object representing the types of an active view transition. This enables the types to be queried or modified on-the-fly during a transition.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ViewTransitionTypeSet)
 */
interface ViewTransitionTypeSet {
    forEach(callbackfn: (value: string, key: string, parent: ViewTransitionTypeSet) => void, thisArg?: any): void;
}

declare var ViewTransitionTypeSet: {
    prototype: ViewTransitionTypeSet;
    new(): ViewTransitionTypeSet;
};

interface VisualViewportEventMap {
    "resize": Event;
    "scroll": Event;
}

/**
 * The **`VisualViewport`** interface of the CSSOM view API represents the visual viewport for a given window. For a page containing iframes, each iframe, as well as the containing page, will have a unique window object. Each window on a page will have a unique VisualViewport representing the properties associated with that window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport)
 */
interface VisualViewport extends EventTarget {
    /**
     * The **`height`** read-only property of the VisualViewport interface returns the height of the visual viewport, in CSS pixels, or 0 if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/height)
     */
    readonly height: number;
    /**
     * The **`offsetLeft`** read-only property of the VisualViewport interface returns the offset of the left edge of the visual viewport from the left edge of the layout viewport in CSS pixels, or 0 if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/offsetLeft)
     */
    readonly offsetLeft: number;
    /**
     * The **`offsetTop`** read-only property of the VisualViewport interface returns the offset of the top edge of the visual viewport from the top edge of the layout viewport in CSS pixels, or 0 if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/offsetTop)
     */
    readonly offsetTop: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/resize_event) */
    onresize: ((this: VisualViewport, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/scroll_event) */
    onscroll: ((this: VisualViewport, ev: Event) => any) | null;
    /**
     * The **`pageLeft`** read-only property of the VisualViewport interface returns the x coordinate of the left edge of the visual viewport relative to the initial containing block origin, in CSS pixels, or 0 if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/pageLeft)
     */
    readonly pageLeft: number;
    /**
     * The **`pageTop`** read-only property of the VisualViewport interface returns the y coordinate of the top edge of the visual viewport relative to the initial containing block origin, in CSS pixels, or 0 if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/pageTop)
     */
    readonly pageTop: number;
    /**
     * The **`scale`** read-only property of the VisualViewport interface returns the pinch-zoom scaling factor applied to the visual viewport, or 0 if current document is not fully active, or 1 if there is no output device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/scale)
     */
    readonly scale: number;
    /**
     * The **`width`** read-only property of the VisualViewport interface returns the width of the visual viewport, in CSS pixels, or 0 if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/VisualViewport/width)
     */
    readonly width: number;
    addEventListener<K extends keyof VisualViewportEventMap>(type: K, listener: (this: VisualViewport, ev: VisualViewportEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof VisualViewportEventMap>(type: K, listener: (this: VisualViewport, ev: VisualViewportEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var VisualViewport: {
    prototype: VisualViewport;
    new(): VisualViewport;
};

/**
 * The **`WEBGL_color_buffer_float`** extension is part of the WebGL API and adds the ability to render to 32-bit floating-point color buffers.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_color_buffer_float)
 */
interface WEBGL_color_buffer_float {
    readonly RGBA32F_EXT: 0x8814;
    readonly FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE_EXT: 0x8211;
    readonly UNSIGNED_NORMALIZED_EXT: 0x8C17;
}

/**
 * The **`WEBGL_compressed_texture_astc`** extension is part of the WebGL API and exposes Adaptive Scalable Texture Compression (ASTC) compressed texture formats to WebGL.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_astc)
 */
interface WEBGL_compressed_texture_astc {
    /**
     * The **`WEBGL_compressed_texture_astc.getSupportedProfiles()`** method returns an array of strings containing the names of the ASTC profiles supported by the implementation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_astc/getSupportedProfiles)
     */
    getSupportedProfiles(): string[];
    readonly COMPRESSED_RGBA_ASTC_4x4_KHR: 0x93B0;
    readonly COMPRESSED_RGBA_ASTC_5x4_KHR: 0x93B1;
    readonly COMPRESSED_RGBA_ASTC_5x5_KHR: 0x93B2;
    readonly COMPRESSED_RGBA_ASTC_6x5_KHR: 0x93B3;
    readonly COMPRESSED_RGBA_ASTC_6x6_KHR: 0x93B4;
    readonly COMPRESSED_RGBA_ASTC_8x5_KHR: 0x93B5;
    readonly COMPRESSED_RGBA_ASTC_8x6_KHR: 0x93B6;
    readonly COMPRESSED_RGBA_ASTC_8x8_KHR: 0x93B7;
    readonly COMPRESSED_RGBA_ASTC_10x5_KHR: 0x93B8;
    readonly COMPRESSED_RGBA_ASTC_10x6_KHR: 0x93B9;
    readonly COMPRESSED_RGBA_ASTC_10x8_KHR: 0x93BA;
    readonly COMPRESSED_RGBA_ASTC_10x10_KHR: 0x93BB;
    readonly COMPRESSED_RGBA_ASTC_12x10_KHR: 0x93BC;
    readonly COMPRESSED_RGBA_ASTC_12x12_KHR: 0x93BD;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR: 0x93D0;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR: 0x93D1;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR: 0x93D2;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR: 0x93D3;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR: 0x93D4;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR: 0x93D5;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR: 0x93D6;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR: 0x93D7;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR: 0x93D8;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR: 0x93D9;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR: 0x93DA;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR: 0x93DB;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR: 0x93DC;
    readonly COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR: 0x93DD;
}

/**
 * The **`WEBGL_compressed_texture_etc`** extension is part of the WebGL API and exposes 10 ETC/EAC compressed texture formats.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_etc)
 */
interface WEBGL_compressed_texture_etc {
    readonly COMPRESSED_R11_EAC: 0x9270;
    readonly COMPRESSED_SIGNED_R11_EAC: 0x9271;
    readonly COMPRESSED_RG11_EAC: 0x9272;
    readonly COMPRESSED_SIGNED_RG11_EAC: 0x9273;
    readonly COMPRESSED_RGB8_ETC2: 0x9274;
    readonly COMPRESSED_SRGB8_ETC2: 0x9275;
    readonly COMPRESSED_RGB8_PUNCHTHROUGH_ALPHA1_ETC2: 0x9276;
    readonly COMPRESSED_SRGB8_PUNCHTHROUGH_ALPHA1_ETC2: 0x9277;
    readonly COMPRESSED_RGBA8_ETC2_EAC: 0x9278;
    readonly COMPRESSED_SRGB8_ALPHA8_ETC2_EAC: 0x9279;
}

/**
 * The **`WEBGL_compressed_texture_etc1`** extension is part of the WebGL API and exposes the ETC1 compressed texture format.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_etc1)
 */
interface WEBGL_compressed_texture_etc1 {
    readonly COMPRESSED_RGB_ETC1_WEBGL: 0x8D64;
}

/**
 * The **`WEBGL_compressed_texture_pvrtc`** extension is part of the WebGL API and exposes four PVRTC compressed texture formats.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_pvrtc)
 */
interface WEBGL_compressed_texture_pvrtc {
    readonly COMPRESSED_RGB_PVRTC_4BPPV1_IMG: 0x8C00;
    readonly COMPRESSED_RGB_PVRTC_2BPPV1_IMG: 0x8C01;
    readonly COMPRESSED_RGBA_PVRTC_4BPPV1_IMG: 0x8C02;
    readonly COMPRESSED_RGBA_PVRTC_2BPPV1_IMG: 0x8C03;
}

/**
 * The **`WEBGL_compressed_texture_s3tc`** extension is part of the WebGL API and exposes four S3TC compressed texture formats.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_s3tc)
 */
interface WEBGL_compressed_texture_s3tc {
    readonly COMPRESSED_RGB_S3TC_DXT1_EXT: 0x83F0;
    readonly COMPRESSED_RGBA_S3TC_DXT1_EXT: 0x83F1;
    readonly COMPRESSED_RGBA_S3TC_DXT3_EXT: 0x83F2;
    readonly COMPRESSED_RGBA_S3TC_DXT5_EXT: 0x83F3;
}

/**
 * The **`WEBGL_compressed_texture_s3tc_srgb`** extension is part of the WebGL API and exposes four S3TC compressed texture formats for the sRGB colorspace.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_compressed_texture_s3tc_srgb)
 */
interface WEBGL_compressed_texture_s3tc_srgb {
    readonly COMPRESSED_SRGB_S3TC_DXT1_EXT: 0x8C4C;
    readonly COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT: 0x8C4D;
    readonly COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT: 0x8C4E;
    readonly COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT: 0x8C4F;
}

/**
 * The **`WEBGL_debug_renderer_info`** extension is part of the WebGL API and exposes two constants with information about the graphics driver for debugging purposes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_debug_renderer_info)
 */
interface WEBGL_debug_renderer_info {
    readonly UNMASKED_VENDOR_WEBGL: 0x9245;
    readonly UNMASKED_RENDERER_WEBGL: 0x9246;
}

/**
 * The **`WEBGL_debug_shaders`** extension is part of the WebGL API and exposes a method to debug shaders from privileged contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_debug_shaders)
 */
interface WEBGL_debug_shaders {
    /**
     * The **`WEBGL_debug_shaders.getTranslatedShaderSource()`** method is part of the WebGL API and allows you to debug a translated shader.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_debug_shaders/getTranslatedShaderSource)
     */
    getTranslatedShaderSource(shader: WebGLShader): string;
}

/**
 * The **`WEBGL_depth_texture`** extension is part of the WebGL API and defines 2D depth and depth-stencil textures.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_depth_texture)
 */
interface WEBGL_depth_texture {
    readonly UNSIGNED_INT_24_8_WEBGL: 0x84FA;
}

/**
 * The **`WEBGL_draw_buffers`** extension is part of the WebGL API and enables a fragment shader to write to several textures, which is useful for deferred shading, for example.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_draw_buffers)
 */
interface WEBGL_draw_buffers {
    /**
     * The **`WEBGL_draw_buffers.drawBuffersWEBGL()`** method is part of the WebGL API and allows you to define the draw buffers to which all fragment colors are written.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_draw_buffers/drawBuffersWEBGL)
     */
    drawBuffersWEBGL(buffers: GLenum[]): void;
    readonly COLOR_ATTACHMENT0_WEBGL: 0x8CE0;
    readonly COLOR_ATTACHMENT1_WEBGL: 0x8CE1;
    readonly COLOR_ATTACHMENT2_WEBGL: 0x8CE2;
    readonly COLOR_ATTACHMENT3_WEBGL: 0x8CE3;
    readonly COLOR_ATTACHMENT4_WEBGL: 0x8CE4;
    readonly COLOR_ATTACHMENT5_WEBGL: 0x8CE5;
    readonly COLOR_ATTACHMENT6_WEBGL: 0x8CE6;
    readonly COLOR_ATTACHMENT7_WEBGL: 0x8CE7;
    readonly COLOR_ATTACHMENT8_WEBGL: 0x8CE8;
    readonly COLOR_ATTACHMENT9_WEBGL: 0x8CE9;
    readonly COLOR_ATTACHMENT10_WEBGL: 0x8CEA;
    readonly COLOR_ATTACHMENT11_WEBGL: 0x8CEB;
    readonly COLOR_ATTACHMENT12_WEBGL: 0x8CEC;
    readonly COLOR_ATTACHMENT13_WEBGL: 0x8CED;
    readonly COLOR_ATTACHMENT14_WEBGL: 0x8CEE;
    readonly COLOR_ATTACHMENT15_WEBGL: 0x8CEF;
    readonly DRAW_BUFFER0_WEBGL: 0x8825;
    readonly DRAW_BUFFER1_WEBGL: 0x8826;
    readonly DRAW_BUFFER2_WEBGL: 0x8827;
    readonly DRAW_BUFFER3_WEBGL: 0x8828;
    readonly DRAW_BUFFER4_WEBGL: 0x8829;
    readonly DRAW_BUFFER5_WEBGL: 0x882A;
    readonly DRAW_BUFFER6_WEBGL: 0x882B;
    readonly DRAW_BUFFER7_WEBGL: 0x882C;
    readonly DRAW_BUFFER8_WEBGL: 0x882D;
    readonly DRAW_BUFFER9_WEBGL: 0x882E;
    readonly DRAW_BUFFER10_WEBGL: 0x882F;
    readonly DRAW_BUFFER11_WEBGL: 0x8830;
    readonly DRAW_BUFFER12_WEBGL: 0x8831;
    readonly DRAW_BUFFER13_WEBGL: 0x8832;
    readonly DRAW_BUFFER14_WEBGL: 0x8833;
    readonly DRAW_BUFFER15_WEBGL: 0x8834;
    readonly MAX_COLOR_ATTACHMENTS_WEBGL: 0x8CDF;
    readonly MAX_DRAW_BUFFERS_WEBGL: 0x8824;
}

/**
 * The **`WEBGL_lose_context`** extension is part of the WebGL API and exposes functions to simulate losing and restoring a WebGLRenderingContext.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_lose_context)
 */
interface WEBGL_lose_context {
    /**
     * The **`WEBGL_lose_context.loseContext()`** method is part of the WebGL API and allows you to simulate losing the context of a WebGLRenderingContext context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_lose_context/loseContext)
     */
    loseContext(): void;
    /**
     * The **`WEBGL_lose_context.restoreContext()`** method is part of the WebGL API and allows you to simulate restoring the context of a WebGLRenderingContext object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_lose_context/restoreContext)
     */
    restoreContext(): void;
}

/**
 * The **`WEBGL_multi_draw`** extension is part of the WebGL API and allows to render more than one primitive with a single function call. This can improve a WebGL application's performance as it reduces binding costs in the renderer and speeds up GPU thread time with uniform data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw)
 */
interface WEBGL_multi_draw {
    /**
     * The **`WEBGL_multi_draw.multiDrawArraysInstancedWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawArraysInstanced() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawArraysInstancedWEBGL)
     */
    multiDrawArraysInstancedWEBGL(mode: GLenum, firstsList: Int32Array<ArrayBufferLike> | GLint[], firstsOffset: number, countsList: Int32Array<ArrayBufferLike> | GLsizei[], countsOffset: number, instanceCountsList: Int32Array<ArrayBufferLike> | GLsizei[], instanceCountsOffset: number, drawcount: GLsizei): void;
    /**
     * The **`WEBGL_multi_draw.multiDrawArraysWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawArrays() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawArraysWEBGL)
     */
    multiDrawArraysWEBGL(mode: GLenum, firstsList: Int32Array<ArrayBufferLike> | GLint[], firstsOffset: number, countsList: Int32Array<ArrayBufferLike> | GLsizei[], countsOffset: number, drawcount: GLsizei): void;
    /**
     * The **`WEBGL_multi_draw.multiDrawElementsInstancedWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawElementsInstanced() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawElementsInstancedWEBGL)
     */
    multiDrawElementsInstancedWEBGL(mode: GLenum, countsList: Int32Array<ArrayBufferLike> | GLsizei[], countsOffset: number, type: GLenum, offsetsList: Int32Array<ArrayBufferLike> | GLsizei[], offsetsOffset: number, instanceCountsList: Int32Array<ArrayBufferLike> | GLsizei[], instanceCountsOffset: number, drawcount: GLsizei): void;
    /**
     * The **`WEBGL_multi_draw.multiDrawElementsWEBGL()`** method of the WebGL API renders multiple primitives from array data. It is identical to multiple calls to the gl.drawElements() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WEBGL_multi_draw/multiDrawElementsWEBGL)
     */
    multiDrawElementsWEBGL(mode: GLenum, countsList: Int32Array<ArrayBufferLike> | GLsizei[], countsOffset: number, type: GLenum, offsetsList: Int32Array<ArrayBufferLike> | GLsizei[], offsetsOffset: number, drawcount: GLsizei): void;
}

/**
 * The **`WGSLLanguageFeatures`** interface of the WebGPU API is a setlike object that reports the WGSL language extensions supported by the WebGPU implementation.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WGSLLanguageFeatures)
 */
interface WGSLLanguageFeatures {
    forEach(callbackfn: (value: string, key: string, parent: WGSLLanguageFeatures) => void, thisArg?: any): void;
}

declare var WGSLLanguageFeatures: {
    prototype: WGSLLanguageFeatures;
    new(): WGSLLanguageFeatures;
};

/**
 * The **`WakeLock`** interface of the Screen Wake Lock API can be used to request a lock that prevents device screens from dimming or locking when an application needs to keep running.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLock)
 */
interface WakeLock {
    /**
     * The **`request()`** method of the WakeLock interface returns a Promise that fulfills with a WakeLockSentinel object if the system screen wake lock is granted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLock/request)
     */
    request(type?: WakeLockType): Promise<WakeLockSentinel>;
}

declare var WakeLock: {
    prototype: WakeLock;
    new(): WakeLock;
};

interface WakeLockSentinelEventMap {
    "release": Event;
}

/**
 * The **`WakeLockSentinel`** interface of the Screen Wake Lock API can be used to monitor the status of the platform screen wake lock, and manually release the lock when needed.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLockSentinel)
 */
interface WakeLockSentinel extends EventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLockSentinel/release_event) */
    onrelease: ((this: WakeLockSentinel, ev: Event) => any) | null;
    /**
     * The **`released`** read-only property of the WakeLockSentinel interface returns a boolean that indicates whether a WakeLockSentinel has been released.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLockSentinel/released)
     */
    readonly released: boolean;
    /**
     * The **`type`** read-only property of the WakeLockSentinel interface returns a string representation of the currently acquired WakeLockSentinel type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLockSentinel/type)
     */
    readonly type: WakeLockType;
    /**
     * The **`release()`** method of the WakeLockSentinel interface releases the WakeLockSentinel, returning a Promise that is resolved once the sentinel has been successfully released.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WakeLockSentinel/release)
     */
    release(): Promise<void>;
    addEventListener<K extends keyof WakeLockSentinelEventMap>(type: K, listener: (this: WakeLockSentinel, ev: WakeLockSentinelEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof WakeLockSentinelEventMap>(type: K, listener: (this: WakeLockSentinel, ev: WakeLockSentinelEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var WakeLockSentinel: {
    prototype: WakeLockSentinel;
    new(): WakeLockSentinel;
};

/**
 * The **`WaveShaperNode`** interface represents a non-linear distorter.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WaveShaperNode)
 */
interface WaveShaperNode extends AudioNode {
    /**
     * The **`curve`** property of the WaveShaperNode interface is a Float32Array of numbers describing the distortion to apply.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WaveShaperNode/curve)
     */
    curve: Float32Array<ArrayBuffer> | null;
    /**
     * The **`oversample`** property of the WaveShaperNode interface is an enumerated value indicating if oversampling must be used. Oversampling is a technique for creating more samples (up-sampling) before applying a distortion effect to the audio signal.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WaveShaperNode/oversample)
     */
    oversample: OverSampleType;
}

declare var WaveShaperNode: {
    prototype: WaveShaperNode;
    new(context: BaseAudioContext, options?: WaveShaperOptions): WaveShaperNode;
};

/**
 * The **`WebGL2RenderingContext`** interface provides the OpenGL ES 3.0 rendering context for the drawing surface of an HTML <canvas> element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext)
 */
interface WebGL2RenderingContext extends WebGL2RenderingContextBase, WebGL2RenderingContextOverloads, WebGLRenderingContextBase {
}

declare var WebGL2RenderingContext: {
    prototype: WebGL2RenderingContext;
    new(): WebGL2RenderingContext;
    readonly READ_BUFFER: 0x0C02;
    readonly UNPACK_ROW_LENGTH: 0x0CF2;
    readonly UNPACK_SKIP_ROWS: 0x0CF3;
    readonly UNPACK_SKIP_PIXELS: 0x0CF4;
    readonly PACK_ROW_LENGTH: 0x0D02;
    readonly PACK_SKIP_ROWS: 0x0D03;
    readonly PACK_SKIP_PIXELS: 0x0D04;
    readonly COLOR: 0x1800;
    readonly DEPTH: 0x1801;
    readonly STENCIL: 0x1802;
    readonly RED: 0x1903;
    readonly RGB8: 0x8051;
    readonly RGB10_A2: 0x8059;
    readonly TEXTURE_BINDING_3D: 0x806A;
    readonly UNPACK_SKIP_IMAGES: 0x806D;
    readonly UNPACK_IMAGE_HEIGHT: 0x806E;
    readonly TEXTURE_3D: 0x806F;
    readonly TEXTURE_WRAP_R: 0x8072;
    readonly MAX_3D_TEXTURE_SIZE: 0x8073;
    readonly UNSIGNED_INT_2_10_10_10_REV: 0x8368;
    readonly MAX_ELEMENTS_VERTICES: 0x80E8;
    readonly MAX_ELEMENTS_INDICES: 0x80E9;
    readonly TEXTURE_MIN_LOD: 0x813A;
    readonly TEXTURE_MAX_LOD: 0x813B;
    readonly TEXTURE_BASE_LEVEL: 0x813C;
    readonly TEXTURE_MAX_LEVEL: 0x813D;
    readonly MIN: 0x8007;
    readonly MAX: 0x8008;
    readonly DEPTH_COMPONENT24: 0x81A6;
    readonly MAX_TEXTURE_LOD_BIAS: 0x84FD;
    readonly TEXTURE_COMPARE_MODE: 0x884C;
    readonly TEXTURE_COMPARE_FUNC: 0x884D;
    readonly CURRENT_QUERY: 0x8865;
    readonly QUERY_RESULT: 0x8866;
    readonly QUERY_RESULT_AVAILABLE: 0x8867;
    readonly STREAM_READ: 0x88E1;
    readonly STREAM_COPY: 0x88E2;
    readonly STATIC_READ: 0x88E5;
    readonly STATIC_COPY: 0x88E6;
    readonly DYNAMIC_READ: 0x88E9;
    readonly DYNAMIC_COPY: 0x88EA;
    readonly MAX_DRAW_BUFFERS: 0x8824;
    readonly DRAW_BUFFER0: 0x8825;
    readonly DRAW_BUFFER1: 0x8826;
    readonly DRAW_BUFFER2: 0x8827;
    readonly DRAW_BUFFER3: 0x8828;
    readonly DRAW_BUFFER4: 0x8829;
    readonly DRAW_BUFFER5: 0x882A;
    readonly DRAW_BUFFER6: 0x882B;
    readonly DRAW_BUFFER7: 0x882C;
    readonly DRAW_BUFFER8: 0x882D;
    readonly DRAW_BUFFER9: 0x882E;
    readonly DRAW_BUFFER10: 0x882F;
    readonly DRAW_BUFFER11: 0x8830;
    readonly DRAW_BUFFER12: 0x8831;
    readonly DRAW_BUFFER13: 0x8832;
    readonly DRAW_BUFFER14: 0x8833;
    readonly DRAW_BUFFER15: 0x8834;
    readonly MAX_FRAGMENT_UNIFORM_COMPONENTS: 0x8B49;
    readonly MAX_VERTEX_UNIFORM_COMPONENTS: 0x8B4A;
    readonly SAMPLER_3D: 0x8B5F;
    readonly SAMPLER_2D_SHADOW: 0x8B62;
    readonly FRAGMENT_SHADER_DERIVATIVE_HINT: 0x8B8B;
    readonly PIXEL_PACK_BUFFER: 0x88EB;
    readonly PIXEL_UNPACK_BUFFER: 0x88EC;
    readonly PIXEL_PACK_BUFFER_BINDING: 0x88ED;
    readonly PIXEL_UNPACK_BUFFER_BINDING: 0x88EF;
    readonly FLOAT_MAT2x3: 0x8B65;
    readonly FLOAT_MAT2x4: 0x8B66;
    readonly FLOAT_MAT3x2: 0x8B67;
    readonly FLOAT_MAT3x4: 0x8B68;
    readonly FLOAT_MAT4x2: 0x8B69;
    readonly FLOAT_MAT4x3: 0x8B6A;
    readonly SRGB: 0x8C40;
    readonly SRGB8: 0x8C41;
    readonly SRGB8_ALPHA8: 0x8C43;
    readonly COMPARE_REF_TO_TEXTURE: 0x884E;
    readonly RGBA32F: 0x8814;
    readonly RGB32F: 0x8815;
    readonly RGBA16F: 0x881A;
    readonly RGB16F: 0x881B;
    readonly VERTEX_ATTRIB_ARRAY_INTEGER: 0x88FD;
    readonly MAX_ARRAY_TEXTURE_LAYERS: 0x88FF;
    readonly MIN_PROGRAM_TEXEL_OFFSET: 0x8904;
    readonly MAX_PROGRAM_TEXEL_OFFSET: 0x8905;
    readonly MAX_VARYING_COMPONENTS: 0x8B4B;
    readonly TEXTURE_2D_ARRAY: 0x8C1A;
    readonly TEXTURE_BINDING_2D_ARRAY: 0x8C1D;
    readonly R11F_G11F_B10F: 0x8C3A;
    readonly UNSIGNED_INT_10F_11F_11F_REV: 0x8C3B;
    readonly RGB9_E5: 0x8C3D;
    readonly UNSIGNED_INT_5_9_9_9_REV: 0x8C3E;
    readonly TRANSFORM_FEEDBACK_BUFFER_MODE: 0x8C7F;
    readonly MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS: 0x8C80;
    readonly TRANSFORM_FEEDBACK_VARYINGS: 0x8C83;
    readonly TRANSFORM_FEEDBACK_BUFFER_START: 0x8C84;
    readonly TRANSFORM_FEEDBACK_BUFFER_SIZE: 0x8C85;
    readonly TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN: 0x8C88;
    readonly RASTERIZER_DISCARD: 0x8C89;
    readonly MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: 0x8C8A;
    readonly MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: 0x8C8B;
    readonly INTERLEAVED_ATTRIBS: 0x8C8C;
    readonly SEPARATE_ATTRIBS: 0x8C8D;
    readonly TRANSFORM_FEEDBACK_BUFFER: 0x8C8E;
    readonly TRANSFORM_FEEDBACK_BUFFER_BINDING: 0x8C8F;
    readonly RGBA32UI: 0x8D70;
    readonly RGB32UI: 0x8D71;
    readonly RGBA16UI: 0x8D76;
    readonly RGB16UI: 0x8D77;
    readonly RGBA8UI: 0x8D7C;
    readonly RGB8UI: 0x8D7D;
    readonly RGBA32I: 0x8D82;
    readonly RGB32I: 0x8D83;
    readonly RGBA16I: 0x8D88;
    readonly RGB16I: 0x8D89;
    readonly RGBA8I: 0x8D8E;
    readonly RGB8I: 0x8D8F;
    readonly RED_INTEGER: 0x8D94;
    readonly RGB_INTEGER: 0x8D98;
    readonly RGBA_INTEGER: 0x8D99;
    readonly SAMPLER_2D_ARRAY: 0x8DC1;
    readonly SAMPLER_2D_ARRAY_SHADOW: 0x8DC4;
    readonly SAMPLER_CUBE_SHADOW: 0x8DC5;
    readonly UNSIGNED_INT_VEC2: 0x8DC6;
    readonly UNSIGNED_INT_VEC3: 0x8DC7;
    readonly UNSIGNED_INT_VEC4: 0x8DC8;
    readonly INT_SAMPLER_2D: 0x8DCA;
    readonly INT_SAMPLER_3D: 0x8DCB;
    readonly INT_SAMPLER_CUBE: 0x8DCC;
    readonly INT_SAMPLER_2D_ARRAY: 0x8DCF;
    readonly UNSIGNED_INT_SAMPLER_2D: 0x8DD2;
    readonly UNSIGNED_INT_SAMPLER_3D: 0x8DD3;
    readonly UNSIGNED_INT_SAMPLER_CUBE: 0x8DD4;
    readonly UNSIGNED_INT_SAMPLER_2D_ARRAY: 0x8DD7;
    readonly DEPTH_COMPONENT32F: 0x8CAC;
    readonly DEPTH32F_STENCIL8: 0x8CAD;
    readonly FLOAT_32_UNSIGNED_INT_24_8_REV: 0x8DAD;
    readonly FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING: 0x8210;
    readonly FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE: 0x8211;
    readonly FRAMEBUFFER_ATTACHMENT_RED_SIZE: 0x8212;
    readonly FRAMEBUFFER_ATTACHMENT_GREEN_SIZE: 0x8213;
    readonly FRAMEBUFFER_ATTACHMENT_BLUE_SIZE: 0x8214;
    readonly FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE: 0x8215;
    readonly FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE: 0x8216;
    readonly FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE: 0x8217;
    readonly FRAMEBUFFER_DEFAULT: 0x8218;
    readonly UNSIGNED_INT_24_8: 0x84FA;
    readonly DEPTH24_STENCIL8: 0x88F0;
    readonly UNSIGNED_NORMALIZED: 0x8C17;
    readonly DRAW_FRAMEBUFFER_BINDING: 0x8CA6;
    readonly READ_FRAMEBUFFER: 0x8CA8;
    readonly DRAW_FRAMEBUFFER: 0x8CA9;
    readonly READ_FRAMEBUFFER_BINDING: 0x8CAA;
    readonly RENDERBUFFER_SAMPLES: 0x8CAB;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER: 0x8CD4;
    readonly MAX_COLOR_ATTACHMENTS: 0x8CDF;
    readonly COLOR_ATTACHMENT1: 0x8CE1;
    readonly COLOR_ATTACHMENT2: 0x8CE2;
    readonly COLOR_ATTACHMENT3: 0x8CE3;
    readonly COLOR_ATTACHMENT4: 0x8CE4;
    readonly COLOR_ATTACHMENT5: 0x8CE5;
    readonly COLOR_ATTACHMENT6: 0x8CE6;
    readonly COLOR_ATTACHMENT7: 0x8CE7;
    readonly COLOR_ATTACHMENT8: 0x8CE8;
    readonly COLOR_ATTACHMENT9: 0x8CE9;
    readonly COLOR_ATTACHMENT10: 0x8CEA;
    readonly COLOR_ATTACHMENT11: 0x8CEB;
    readonly COLOR_ATTACHMENT12: 0x8CEC;
    readonly COLOR_ATTACHMENT13: 0x8CED;
    readonly COLOR_ATTACHMENT14: 0x8CEE;
    readonly COLOR_ATTACHMENT15: 0x8CEF;
    readonly FRAMEBUFFER_INCOMPLETE_MULTISAMPLE: 0x8D56;
    readonly MAX_SAMPLES: 0x8D57;
    readonly HALF_FLOAT: 0x140B;
    readonly RG: 0x8227;
    readonly RG_INTEGER: 0x8228;
    readonly R8: 0x8229;
    readonly RG8: 0x822B;
    readonly R16F: 0x822D;
    readonly R32F: 0x822E;
    readonly RG16F: 0x822F;
    readonly RG32F: 0x8230;
    readonly R8I: 0x8231;
    readonly R8UI: 0x8232;
    readonly R16I: 0x8233;
    readonly R16UI: 0x8234;
    readonly R32I: 0x8235;
    readonly R32UI: 0x8236;
    readonly RG8I: 0x8237;
    readonly RG8UI: 0x8238;
    readonly RG16I: 0x8239;
    readonly RG16UI: 0x823A;
    readonly RG32I: 0x823B;
    readonly RG32UI: 0x823C;
    readonly VERTEX_ARRAY_BINDING: 0x85B5;
    readonly R8_SNORM: 0x8F94;
    readonly RG8_SNORM: 0x8F95;
    readonly RGB8_SNORM: 0x8F96;
    readonly RGBA8_SNORM: 0x8F97;
    readonly SIGNED_NORMALIZED: 0x8F9C;
    readonly COPY_READ_BUFFER: 0x8F36;
    readonly COPY_WRITE_BUFFER: 0x8F37;
    readonly COPY_READ_BUFFER_BINDING: 0x8F36;
    readonly COPY_WRITE_BUFFER_BINDING: 0x8F37;
    readonly UNIFORM_BUFFER: 0x8A11;
    readonly UNIFORM_BUFFER_BINDING: 0x8A28;
    readonly UNIFORM_BUFFER_START: 0x8A29;
    readonly UNIFORM_BUFFER_SIZE: 0x8A2A;
    readonly MAX_VERTEX_UNIFORM_BLOCKS: 0x8A2B;
    readonly MAX_FRAGMENT_UNIFORM_BLOCKS: 0x8A2D;
    readonly MAX_COMBINED_UNIFORM_BLOCKS: 0x8A2E;
    readonly MAX_UNIFORM_BUFFER_BINDINGS: 0x8A2F;
    readonly MAX_UNIFORM_BLOCK_SIZE: 0x8A30;
    readonly MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS: 0x8A31;
    readonly MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS: 0x8A33;
    readonly UNIFORM_BUFFER_OFFSET_ALIGNMENT: 0x8A34;
    readonly ACTIVE_UNIFORM_BLOCKS: 0x8A36;
    readonly UNIFORM_TYPE: 0x8A37;
    readonly UNIFORM_SIZE: 0x8A38;
    readonly UNIFORM_BLOCK_INDEX: 0x8A3A;
    readonly UNIFORM_OFFSET: 0x8A3B;
    readonly UNIFORM_ARRAY_STRIDE: 0x8A3C;
    readonly UNIFORM_MATRIX_STRIDE: 0x8A3D;
    readonly UNIFORM_IS_ROW_MAJOR: 0x8A3E;
    readonly UNIFORM_BLOCK_BINDING: 0x8A3F;
    readonly UNIFORM_BLOCK_DATA_SIZE: 0x8A40;
    readonly UNIFORM_BLOCK_ACTIVE_UNIFORMS: 0x8A42;
    readonly UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES: 0x8A43;
    readonly UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER: 0x8A44;
    readonly UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER: 0x8A46;
    readonly INVALID_INDEX: 0xFFFFFFFF;
    readonly MAX_VERTEX_OUTPUT_COMPONENTS: 0x9122;
    readonly MAX_FRAGMENT_INPUT_COMPONENTS: 0x9125;
    readonly MAX_SERVER_WAIT_TIMEOUT: 0x9111;
    readonly OBJECT_TYPE: 0x9112;
    readonly SYNC_CONDITION: 0x9113;
    readonly SYNC_STATUS: 0x9114;
    readonly SYNC_FLAGS: 0x9115;
    readonly SYNC_FENCE: 0x9116;
    readonly SYNC_GPU_COMMANDS_COMPLETE: 0x9117;
    readonly UNSIGNALED: 0x9118;
    readonly SIGNALED: 0x9119;
    readonly ALREADY_SIGNALED: 0x911A;
    readonly TIMEOUT_EXPIRED: 0x911B;
    readonly CONDITION_SATISFIED: 0x911C;
    readonly WAIT_FAILED: 0x911D;
    readonly SYNC_FLUSH_COMMANDS_BIT: 0x00000001;
    readonly VERTEX_ATTRIB_ARRAY_DIVISOR: 0x88FE;
    readonly ANY_SAMPLES_PASSED: 0x8C2F;
    readonly ANY_SAMPLES_PASSED_CONSERVATIVE: 0x8D6A;
    readonly SAMPLER_BINDING: 0x8919;
    readonly RGB10_A2UI: 0x906F;
    readonly INT_2_10_10_10_REV: 0x8D9F;
    readonly TRANSFORM_FEEDBACK: 0x8E22;
    readonly TRANSFORM_FEEDBACK_PAUSED: 0x8E23;
    readonly TRANSFORM_FEEDBACK_ACTIVE: 0x8E24;
    readonly TRANSFORM_FEEDBACK_BINDING: 0x8E25;
    readonly TEXTURE_IMMUTABLE_FORMAT: 0x912F;
    readonly MAX_ELEMENT_INDEX: 0x8D6B;
    readonly TEXTURE_IMMUTABLE_LEVELS: 0x82DF;
    readonly TIMEOUT_IGNORED: -1;
    readonly MAX_CLIENT_WAIT_TIMEOUT_WEBGL: 0x9247;
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

interface WebGL2RenderingContextBase {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/beginQuery) */
    beginQuery(target: GLenum, query: WebGLQuery): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/beginTransformFeedback) */
    beginTransformFeedback(primitiveMode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bindBufferBase) */
    bindBufferBase(target: GLenum, index: GLuint, buffer: WebGLBuffer | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bindBufferRange) */
    bindBufferRange(target: GLenum, index: GLuint, buffer: WebGLBuffer | null, offset: GLintptr, size: GLsizeiptr): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bindSampler) */
    bindSampler(unit: GLuint, sampler: WebGLSampler | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bindTransformFeedback) */
    bindTransformFeedback(target: GLenum, tf: WebGLTransformFeedback | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bindVertexArray) */
    bindVertexArray(array: WebGLVertexArrayObject | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/blitFramebuffer) */
    blitFramebuffer(srcX0: GLint, srcY0: GLint, srcX1: GLint, srcY1: GLint, dstX0: GLint, dstY0: GLint, dstX1: GLint, dstY1: GLint, mask: GLbitfield, filter: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferfi(buffer: GLenum, drawbuffer: GLint, depth: GLfloat, stencil: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferfv(buffer: GLenum, drawbuffer: GLint, values: Float32List, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferiv(buffer: GLenum, drawbuffer: GLint, values: Int32List, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clearBuffer) */
    clearBufferuiv(buffer: GLenum, drawbuffer: GLint, values: Uint32List, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/clientWaitSync) */
    clientWaitSync(sync: WebGLSync, flags: GLbitfield, timeout: GLuint64): GLenum;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/compressedTexImage3D) */
    compressedTexImage3D(target: GLenum, level: GLint, internalformat: GLenum, width: GLsizei, height: GLsizei, depth: GLsizei, border: GLint, imageSize: GLsizei, offset: GLintptr): void;
    compressedTexImage3D(target: GLenum, level: GLint, internalformat: GLenum, width: GLsizei, height: GLsizei, depth: GLsizei, border: GLint, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset?: number, srcLengthOverride?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/compressedTexSubImage3D) */
    compressedTexSubImage3D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, zoffset: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, format: GLenum, imageSize: GLsizei, offset: GLintptr): void;
    compressedTexSubImage3D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, zoffset: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, format: GLenum, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset?: number, srcLengthOverride?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/copyBufferSubData) */
    copyBufferSubData(readTarget: GLenum, writeTarget: GLenum, readOffset: GLintptr, writeOffset: GLintptr, size: GLsizeiptr): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/copyTexSubImage3D) */
    copyTexSubImage3D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, zoffset: GLint, x: GLint, y: GLint, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/createQuery) */
    createQuery(): WebGLQuery;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/createSampler) */
    createSampler(): WebGLSampler;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/createTransformFeedback) */
    createTransformFeedback(): WebGLTransformFeedback;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/createVertexArray) */
    createVertexArray(): WebGLVertexArrayObject;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/deleteQuery) */
    deleteQuery(query: WebGLQuery | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/deleteSampler) */
    deleteSampler(sampler: WebGLSampler | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/deleteSync) */
    deleteSync(sync: WebGLSync | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/deleteTransformFeedback) */
    deleteTransformFeedback(tf: WebGLTransformFeedback | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/deleteVertexArray) */
    deleteVertexArray(vertexArray: WebGLVertexArrayObject | null): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/drawArraysInstanced) */
    drawArraysInstanced(mode: GLenum, first: GLint, count: GLsizei, instanceCount: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/drawBuffers) */
    drawBuffers(buffers: GLenum[]): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/drawElementsInstanced) */
    drawElementsInstanced(mode: GLenum, count: GLsizei, type: GLenum, offset: GLintptr, instanceCount: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/drawRangeElements) */
    drawRangeElements(mode: GLenum, start: GLuint, end: GLuint, count: GLsizei, type: GLenum, offset: GLintptr): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/endQuery) */
    endQuery(target: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/endTransformFeedback) */
    endTransformFeedback(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/fenceSync) */
    fenceSync(condition: GLenum, flags: GLbitfield): WebGLSync | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/framebufferTextureLayer) */
    framebufferTextureLayer(target: GLenum, attachment: GLenum, texture: WebGLTexture | null, level: GLint, layer: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getActiveUniformBlockName) */
    getActiveUniformBlockName(program: WebGLProgram, uniformBlockIndex: GLuint): string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getActiveUniformBlockParameter) */
    getActiveUniformBlockParameter(program: WebGLProgram, uniformBlockIndex: GLuint, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getActiveUniforms) */
    getActiveUniforms(program: WebGLProgram, uniformIndices: GLuint[], pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getBufferSubData) */
    getBufferSubData(target: GLenum, srcByteOffset: GLintptr, dstBuffer: ArrayBufferView<ArrayBufferLike>, dstOffset?: number, length?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getFragDataLocation) */
    getFragDataLocation(program: WebGLProgram, name: string): GLint;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getIndexedParameter) */
    getIndexedParameter(target: GLenum, index: GLuint): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getInternalformatParameter) */
    getInternalformatParameter(target: GLenum, internalformat: GLenum, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getQuery) */
    getQuery(target: GLenum, pname: GLenum): WebGLQuery | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getQueryParameter) */
    getQueryParameter(query: WebGLQuery, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getSamplerParameter) */
    getSamplerParameter(sampler: WebGLSampler, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getSyncParameter) */
    getSyncParameter(sync: WebGLSync, pname: GLenum): any;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getTransformFeedbackVarying) */
    getTransformFeedbackVarying(program: WebGLProgram, index: GLuint): WebGLActiveInfo | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getUniformBlockIndex) */
    getUniformBlockIndex(program: WebGLProgram, uniformBlockName: string): GLuint;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/getUniformIndices) */
    getUniformIndices(program: WebGLProgram, uniformNames: string[]): GLuint[] | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/invalidateFramebuffer) */
    invalidateFramebuffer(target: GLenum, attachments: GLenum[]): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/invalidateSubFramebuffer) */
    invalidateSubFramebuffer(target: GLenum, attachments: GLenum[], x: GLint, y: GLint, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/isQuery) */
    isQuery(query: WebGLQuery | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/isSampler) */
    isSampler(sampler: WebGLSampler | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/isSync) */
    isSync(sync: WebGLSync | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/isTransformFeedback) */
    isTransformFeedback(tf: WebGLTransformFeedback | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/isVertexArray) */
    isVertexArray(vertexArray: WebGLVertexArrayObject | null): GLboolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/pauseTransformFeedback) */
    pauseTransformFeedback(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/readBuffer) */
    readBuffer(src: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/renderbufferStorageMultisample) */
    renderbufferStorageMultisample(target: GLenum, samples: GLsizei, internalformat: GLenum, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/resumeTransformFeedback) */
    resumeTransformFeedback(): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/samplerParameter) */
    samplerParameterf(sampler: WebGLSampler, pname: GLenum, param: GLfloat): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/samplerParameter) */
    samplerParameteri(sampler: WebGLSampler, pname: GLenum, param: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/texImage3D) */
    texImage3D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, border: GLint, format: GLenum, type: GLenum, pboOffset: GLintptr): void;
    texImage3D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, border: GLint, format: GLenum, type: GLenum, source: TexImageSource): void;
    texImage3D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, border: GLint, format: GLenum, type: GLenum, srcData: ArrayBufferView<ArrayBufferLike> | null): void;
    texImage3D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, border: GLint, format: GLenum, type: GLenum, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/texStorage2D) */
    texStorage2D(target: GLenum, levels: GLsizei, internalformat: GLenum, width: GLsizei, height: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/texStorage3D) */
    texStorage3D(target: GLenum, levels: GLsizei, internalformat: GLenum, width: GLsizei, height: GLsizei, depth: GLsizei): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/texSubImage3D) */
    texSubImage3D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, zoffset: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, format: GLenum, type: GLenum, pboOffset: GLintptr): void;
    texSubImage3D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, zoffset: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, format: GLenum, type: GLenum, source: TexImageSource): void;
    texSubImage3D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, zoffset: GLint, width: GLsizei, height: GLsizei, depth: GLsizei, format: GLenum, type: GLenum, srcData: ArrayBufferView<ArrayBufferLike> | null, srcOffset?: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/transformFeedbackVaryings) */
    transformFeedbackVaryings(program: WebGLProgram, varyings: string[], bufferMode: GLenum): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform1ui(location: WebGLUniformLocation | null, v0: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform1uiv(location: WebGLUniformLocation | null, data: Uint32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform2ui(location: WebGLUniformLocation | null, v0: GLuint, v1: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform2uiv(location: WebGLUniformLocation | null, data: Uint32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform3ui(location: WebGLUniformLocation | null, v0: GLuint, v1: GLuint, v2: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform3uiv(location: WebGLUniformLocation | null, data: Uint32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform4ui(location: WebGLUniformLocation | null, v0: GLuint, v1: GLuint, v2: GLuint, v3: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniform) */
    uniform4uiv(location: WebGLUniformLocation | null, data: Uint32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformBlockBinding) */
    uniformBlockBinding(program: WebGLProgram, uniformBlockIndex: GLuint, uniformBlockBinding: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix2x3fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix2x4fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix3x2fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix3x4fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix4x2fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix4x3fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribDivisor) */
    vertexAttribDivisor(index: GLuint, divisor: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribI) */
    vertexAttribI4i(index: GLuint, x: GLint, y: GLint, z: GLint, w: GLint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribI) */
    vertexAttribI4iv(index: GLuint, values: Int32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribI) */
    vertexAttribI4ui(index: GLuint, x: GLuint, y: GLuint, z: GLuint, w: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribI) */
    vertexAttribI4uiv(index: GLuint, values: Uint32List): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/vertexAttribIPointer) */
    vertexAttribIPointer(index: GLuint, size: GLint, type: GLenum, stride: GLsizei, offset: GLintptr): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/waitSync) */
    waitSync(sync: WebGLSync, flags: GLbitfield, timeout: GLint64): void;
    readonly READ_BUFFER: 0x0C02;
    readonly UNPACK_ROW_LENGTH: 0x0CF2;
    readonly UNPACK_SKIP_ROWS: 0x0CF3;
    readonly UNPACK_SKIP_PIXELS: 0x0CF4;
    readonly PACK_ROW_LENGTH: 0x0D02;
    readonly PACK_SKIP_ROWS: 0x0D03;
    readonly PACK_SKIP_PIXELS: 0x0D04;
    readonly COLOR: 0x1800;
    readonly DEPTH: 0x1801;
    readonly STENCIL: 0x1802;
    readonly RED: 0x1903;
    readonly RGB8: 0x8051;
    readonly RGB10_A2: 0x8059;
    readonly TEXTURE_BINDING_3D: 0x806A;
    readonly UNPACK_SKIP_IMAGES: 0x806D;
    readonly UNPACK_IMAGE_HEIGHT: 0x806E;
    readonly TEXTURE_3D: 0x806F;
    readonly TEXTURE_WRAP_R: 0x8072;
    readonly MAX_3D_TEXTURE_SIZE: 0x8073;
    readonly UNSIGNED_INT_2_10_10_10_REV: 0x8368;
    readonly MAX_ELEMENTS_VERTICES: 0x80E8;
    readonly MAX_ELEMENTS_INDICES: 0x80E9;
    readonly TEXTURE_MIN_LOD: 0x813A;
    readonly TEXTURE_MAX_LOD: 0x813B;
    readonly TEXTURE_BASE_LEVEL: 0x813C;
    readonly TEXTURE_MAX_LEVEL: 0x813D;
    readonly MIN: 0x8007;
    readonly MAX: 0x8008;
    readonly DEPTH_COMPONENT24: 0x81A6;
    readonly MAX_TEXTURE_LOD_BIAS: 0x84FD;
    readonly TEXTURE_COMPARE_MODE: 0x884C;
    readonly TEXTURE_COMPARE_FUNC: 0x884D;
    readonly CURRENT_QUERY: 0x8865;
    readonly QUERY_RESULT: 0x8866;
    readonly QUERY_RESULT_AVAILABLE: 0x8867;
    readonly STREAM_READ: 0x88E1;
    readonly STREAM_COPY: 0x88E2;
    readonly STATIC_READ: 0x88E5;
    readonly STATIC_COPY: 0x88E6;
    readonly DYNAMIC_READ: 0x88E9;
    readonly DYNAMIC_COPY: 0x88EA;
    readonly MAX_DRAW_BUFFERS: 0x8824;
    readonly DRAW_BUFFER0: 0x8825;
    readonly DRAW_BUFFER1: 0x8826;
    readonly DRAW_BUFFER2: 0x8827;
    readonly DRAW_BUFFER3: 0x8828;
    readonly DRAW_BUFFER4: 0x8829;
    readonly DRAW_BUFFER5: 0x882A;
    readonly DRAW_BUFFER6: 0x882B;
    readonly DRAW_BUFFER7: 0x882C;
    readonly DRAW_BUFFER8: 0x882D;
    readonly DRAW_BUFFER9: 0x882E;
    readonly DRAW_BUFFER10: 0x882F;
    readonly DRAW_BUFFER11: 0x8830;
    readonly DRAW_BUFFER12: 0x8831;
    readonly DRAW_BUFFER13: 0x8832;
    readonly DRAW_BUFFER14: 0x8833;
    readonly DRAW_BUFFER15: 0x8834;
    readonly MAX_FRAGMENT_UNIFORM_COMPONENTS: 0x8B49;
    readonly MAX_VERTEX_UNIFORM_COMPONENTS: 0x8B4A;
    readonly SAMPLER_3D: 0x8B5F;
    readonly SAMPLER_2D_SHADOW: 0x8B62;
    readonly FRAGMENT_SHADER_DERIVATIVE_HINT: 0x8B8B;
    readonly PIXEL_PACK_BUFFER: 0x88EB;
    readonly PIXEL_UNPACK_BUFFER: 0x88EC;
    readonly PIXEL_PACK_BUFFER_BINDING: 0x88ED;
    readonly PIXEL_UNPACK_BUFFER_BINDING: 0x88EF;
    readonly FLOAT_MAT2x3: 0x8B65;
    readonly FLOAT_MAT2x4: 0x8B66;
    readonly FLOAT_MAT3x2: 0x8B67;
    readonly FLOAT_MAT3x4: 0x8B68;
    readonly FLOAT_MAT4x2: 0x8B69;
    readonly FLOAT_MAT4x3: 0x8B6A;
    readonly SRGB: 0x8C40;
    readonly SRGB8: 0x8C41;
    readonly SRGB8_ALPHA8: 0x8C43;
    readonly COMPARE_REF_TO_TEXTURE: 0x884E;
    readonly RGBA32F: 0x8814;
    readonly RGB32F: 0x8815;
    readonly RGBA16F: 0x881A;
    readonly RGB16F: 0x881B;
    readonly VERTEX_ATTRIB_ARRAY_INTEGER: 0x88FD;
    readonly MAX_ARRAY_TEXTURE_LAYERS: 0x88FF;
    readonly MIN_PROGRAM_TEXEL_OFFSET: 0x8904;
    readonly MAX_PROGRAM_TEXEL_OFFSET: 0x8905;
    readonly MAX_VARYING_COMPONENTS: 0x8B4B;
    readonly TEXTURE_2D_ARRAY: 0x8C1A;
    readonly TEXTURE_BINDING_2D_ARRAY: 0x8C1D;
    readonly R11F_G11F_B10F: 0x8C3A;
    readonly UNSIGNED_INT_10F_11F_11F_REV: 0x8C3B;
    readonly RGB9_E5: 0x8C3D;
    readonly UNSIGNED_INT_5_9_9_9_REV: 0x8C3E;
    readonly TRANSFORM_FEEDBACK_BUFFER_MODE: 0x8C7F;
    readonly MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS: 0x8C80;
    readonly TRANSFORM_FEEDBACK_VARYINGS: 0x8C83;
    readonly TRANSFORM_FEEDBACK_BUFFER_START: 0x8C84;
    readonly TRANSFORM_FEEDBACK_BUFFER_SIZE: 0x8C85;
    readonly TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN: 0x8C88;
    readonly RASTERIZER_DISCARD: 0x8C89;
    readonly MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: 0x8C8A;
    readonly MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: 0x8C8B;
    readonly INTERLEAVED_ATTRIBS: 0x8C8C;
    readonly SEPARATE_ATTRIBS: 0x8C8D;
    readonly TRANSFORM_FEEDBACK_BUFFER: 0x8C8E;
    readonly TRANSFORM_FEEDBACK_BUFFER_BINDING: 0x8C8F;
    readonly RGBA32UI: 0x8D70;
    readonly RGB32UI: 0x8D71;
    readonly RGBA16UI: 0x8D76;
    readonly RGB16UI: 0x8D77;
    readonly RGBA8UI: 0x8D7C;
    readonly RGB8UI: 0x8D7D;
    readonly RGBA32I: 0x8D82;
    readonly RGB32I: 0x8D83;
    readonly RGBA16I: 0x8D88;
    readonly RGB16I: 0x8D89;
    readonly RGBA8I: 0x8D8E;
    readonly RGB8I: 0x8D8F;
    readonly RED_INTEGER: 0x8D94;
    readonly RGB_INTEGER: 0x8D98;
    readonly RGBA_INTEGER: 0x8D99;
    readonly SAMPLER_2D_ARRAY: 0x8DC1;
    readonly SAMPLER_2D_ARRAY_SHADOW: 0x8DC4;
    readonly SAMPLER_CUBE_SHADOW: 0x8DC5;
    readonly UNSIGNED_INT_VEC2: 0x8DC6;
    readonly UNSIGNED_INT_VEC3: 0x8DC7;
    readonly UNSIGNED_INT_VEC4: 0x8DC8;
    readonly INT_SAMPLER_2D: 0x8DCA;
    readonly INT_SAMPLER_3D: 0x8DCB;
    readonly INT_SAMPLER_CUBE: 0x8DCC;
    readonly INT_SAMPLER_2D_ARRAY: 0x8DCF;
    readonly UNSIGNED_INT_SAMPLER_2D: 0x8DD2;
    readonly UNSIGNED_INT_SAMPLER_3D: 0x8DD3;
    readonly UNSIGNED_INT_SAMPLER_CUBE: 0x8DD4;
    readonly UNSIGNED_INT_SAMPLER_2D_ARRAY: 0x8DD7;
    readonly DEPTH_COMPONENT32F: 0x8CAC;
    readonly DEPTH32F_STENCIL8: 0x8CAD;
    readonly FLOAT_32_UNSIGNED_INT_24_8_REV: 0x8DAD;
    readonly FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING: 0x8210;
    readonly FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE: 0x8211;
    readonly FRAMEBUFFER_ATTACHMENT_RED_SIZE: 0x8212;
    readonly FRAMEBUFFER_ATTACHMENT_GREEN_SIZE: 0x8213;
    readonly FRAMEBUFFER_ATTACHMENT_BLUE_SIZE: 0x8214;
    readonly FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE: 0x8215;
    readonly FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE: 0x8216;
    readonly FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE: 0x8217;
    readonly FRAMEBUFFER_DEFAULT: 0x8218;
    readonly UNSIGNED_INT_24_8: 0x84FA;
    readonly DEPTH24_STENCIL8: 0x88F0;
    readonly UNSIGNED_NORMALIZED: 0x8C17;
    readonly DRAW_FRAMEBUFFER_BINDING: 0x8CA6;
    readonly READ_FRAMEBUFFER: 0x8CA8;
    readonly DRAW_FRAMEBUFFER: 0x8CA9;
    readonly READ_FRAMEBUFFER_BINDING: 0x8CAA;
    readonly RENDERBUFFER_SAMPLES: 0x8CAB;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER: 0x8CD4;
    readonly MAX_COLOR_ATTACHMENTS: 0x8CDF;
    readonly COLOR_ATTACHMENT1: 0x8CE1;
    readonly COLOR_ATTACHMENT2: 0x8CE2;
    readonly COLOR_ATTACHMENT3: 0x8CE3;
    readonly COLOR_ATTACHMENT4: 0x8CE4;
    readonly COLOR_ATTACHMENT5: 0x8CE5;
    readonly COLOR_ATTACHMENT6: 0x8CE6;
    readonly COLOR_ATTACHMENT7: 0x8CE7;
    readonly COLOR_ATTACHMENT8: 0x8CE8;
    readonly COLOR_ATTACHMENT9: 0x8CE9;
    readonly COLOR_ATTACHMENT10: 0x8CEA;
    readonly COLOR_ATTACHMENT11: 0x8CEB;
    readonly COLOR_ATTACHMENT12: 0x8CEC;
    readonly COLOR_ATTACHMENT13: 0x8CED;
    readonly COLOR_ATTACHMENT14: 0x8CEE;
    readonly COLOR_ATTACHMENT15: 0x8CEF;
    readonly FRAMEBUFFER_INCOMPLETE_MULTISAMPLE: 0x8D56;
    readonly MAX_SAMPLES: 0x8D57;
    readonly HALF_FLOAT: 0x140B;
    readonly RG: 0x8227;
    readonly RG_INTEGER: 0x8228;
    readonly R8: 0x8229;
    readonly RG8: 0x822B;
    readonly R16F: 0x822D;
    readonly R32F: 0x822E;
    readonly RG16F: 0x822F;
    readonly RG32F: 0x8230;
    readonly R8I: 0x8231;
    readonly R8UI: 0x8232;
    readonly R16I: 0x8233;
    readonly R16UI: 0x8234;
    readonly R32I: 0x8235;
    readonly R32UI: 0x8236;
    readonly RG8I: 0x8237;
    readonly RG8UI: 0x8238;
    readonly RG16I: 0x8239;
    readonly RG16UI: 0x823A;
    readonly RG32I: 0x823B;
    readonly RG32UI: 0x823C;
    readonly VERTEX_ARRAY_BINDING: 0x85B5;
    readonly R8_SNORM: 0x8F94;
    readonly RG8_SNORM: 0x8F95;
    readonly RGB8_SNORM: 0x8F96;
    readonly RGBA8_SNORM: 0x8F97;
    readonly SIGNED_NORMALIZED: 0x8F9C;
    readonly COPY_READ_BUFFER: 0x8F36;
    readonly COPY_WRITE_BUFFER: 0x8F37;
    readonly COPY_READ_BUFFER_BINDING: 0x8F36;
    readonly COPY_WRITE_BUFFER_BINDING: 0x8F37;
    readonly UNIFORM_BUFFER: 0x8A11;
    readonly UNIFORM_BUFFER_BINDING: 0x8A28;
    readonly UNIFORM_BUFFER_START: 0x8A29;
    readonly UNIFORM_BUFFER_SIZE: 0x8A2A;
    readonly MAX_VERTEX_UNIFORM_BLOCKS: 0x8A2B;
    readonly MAX_FRAGMENT_UNIFORM_BLOCKS: 0x8A2D;
    readonly MAX_COMBINED_UNIFORM_BLOCKS: 0x8A2E;
    readonly MAX_UNIFORM_BUFFER_BINDINGS: 0x8A2F;
    readonly MAX_UNIFORM_BLOCK_SIZE: 0x8A30;
    readonly MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS: 0x8A31;
    readonly MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS: 0x8A33;
    readonly UNIFORM_BUFFER_OFFSET_ALIGNMENT: 0x8A34;
    readonly ACTIVE_UNIFORM_BLOCKS: 0x8A36;
    readonly UNIFORM_TYPE: 0x8A37;
    readonly UNIFORM_SIZE: 0x8A38;
    readonly UNIFORM_BLOCK_INDEX: 0x8A3A;
    readonly UNIFORM_OFFSET: 0x8A3B;
    readonly UNIFORM_ARRAY_STRIDE: 0x8A3C;
    readonly UNIFORM_MATRIX_STRIDE: 0x8A3D;
    readonly UNIFORM_IS_ROW_MAJOR: 0x8A3E;
    readonly UNIFORM_BLOCK_BINDING: 0x8A3F;
    readonly UNIFORM_BLOCK_DATA_SIZE: 0x8A40;
    readonly UNIFORM_BLOCK_ACTIVE_UNIFORMS: 0x8A42;
    readonly UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES: 0x8A43;
    readonly UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER: 0x8A44;
    readonly UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER: 0x8A46;
    readonly INVALID_INDEX: 0xFFFFFFFF;
    readonly MAX_VERTEX_OUTPUT_COMPONENTS: 0x9122;
    readonly MAX_FRAGMENT_INPUT_COMPONENTS: 0x9125;
    readonly MAX_SERVER_WAIT_TIMEOUT: 0x9111;
    readonly OBJECT_TYPE: 0x9112;
    readonly SYNC_CONDITION: 0x9113;
    readonly SYNC_STATUS: 0x9114;
    readonly SYNC_FLAGS: 0x9115;
    readonly SYNC_FENCE: 0x9116;
    readonly SYNC_GPU_COMMANDS_COMPLETE: 0x9117;
    readonly UNSIGNALED: 0x9118;
    readonly SIGNALED: 0x9119;
    readonly ALREADY_SIGNALED: 0x911A;
    readonly TIMEOUT_EXPIRED: 0x911B;
    readonly CONDITION_SATISFIED: 0x911C;
    readonly WAIT_FAILED: 0x911D;
    readonly SYNC_FLUSH_COMMANDS_BIT: 0x00000001;
    readonly VERTEX_ATTRIB_ARRAY_DIVISOR: 0x88FE;
    readonly ANY_SAMPLES_PASSED: 0x8C2F;
    readonly ANY_SAMPLES_PASSED_CONSERVATIVE: 0x8D6A;
    readonly SAMPLER_BINDING: 0x8919;
    readonly RGB10_A2UI: 0x906F;
    readonly INT_2_10_10_10_REV: 0x8D9F;
    readonly TRANSFORM_FEEDBACK: 0x8E22;
    readonly TRANSFORM_FEEDBACK_PAUSED: 0x8E23;
    readonly TRANSFORM_FEEDBACK_ACTIVE: 0x8E24;
    readonly TRANSFORM_FEEDBACK_BINDING: 0x8E25;
    readonly TEXTURE_IMMUTABLE_FORMAT: 0x912F;
    readonly MAX_ELEMENT_INDEX: 0x8D6B;
    readonly TEXTURE_IMMUTABLE_LEVELS: 0x82DF;
    readonly TIMEOUT_IGNORED: -1;
    readonly MAX_CLIENT_WAIT_TIMEOUT_WEBGL: 0x9247;
}

interface WebGL2RenderingContextOverloads {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bufferData) */
    bufferData(target: GLenum, size: GLsizeiptr, usage: GLenum): void;
    bufferData(target: GLenum, srcData: AllowSharedBufferSource | null, usage: GLenum): void;
    bufferData(target: GLenum, srcData: ArrayBufferView<ArrayBufferLike>, usage: GLenum, srcOffset: number, length?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/bufferSubData) */
    bufferSubData(target: GLenum, dstByteOffset: GLintptr, srcData: AllowSharedBufferSource): void;
    bufferSubData(target: GLenum, dstByteOffset: GLintptr, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset: number, length?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/compressedTexImage2D) */
    compressedTexImage2D(target: GLenum, level: GLint, internalformat: GLenum, width: GLsizei, height: GLsizei, border: GLint, imageSize: GLsizei, offset: GLintptr): void;
    compressedTexImage2D(target: GLenum, level: GLint, internalformat: GLenum, width: GLsizei, height: GLsizei, border: GLint, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset?: number, srcLengthOverride?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/compressedTexSubImage2D) */
    compressedTexSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, imageSize: GLsizei, offset: GLintptr): void;
    compressedTexSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset?: number, srcLengthOverride?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/readPixels) */
    readPixels(x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, dstData: ArrayBufferView<ArrayBufferLike> | null): void;
    readPixels(x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, offset: GLintptr): void;
    readPixels(x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, dstData: ArrayBufferView<ArrayBufferLike>, dstOffset: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/texImage2D) */
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, pixels: ArrayBufferView<ArrayBufferLike> | null): void;
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, format: GLenum, type: GLenum, source: TexImageSource): void;
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, pboOffset: GLintptr): void;
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, source: TexImageSource): void;
    texImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/texSubImage2D) */
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pixels: ArrayBufferView<ArrayBufferLike> | null): void;
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, format: GLenum, type: GLenum, source: TexImageSource): void;
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pboOffset: GLintptr): void;
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, source: TexImageSource): void;
    texSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, srcData: ArrayBufferView<ArrayBufferLike>, srcOffset: number): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1fv(location: WebGLUniformLocation | null, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform1iv(location: WebGLUniformLocation | null, data: Int32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2fv(location: WebGLUniformLocation | null, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform2iv(location: WebGLUniformLocation | null, data: Int32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3fv(location: WebGLUniformLocation | null, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform3iv(location: WebGLUniformLocation | null, data: Int32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4fv(location: WebGLUniformLocation | null, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniform) */
    uniform4iv(location: WebGLUniformLocation | null, data: Int32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGL2RenderingContext/uniformMatrix) */
    uniformMatrix2fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix3fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/WebGLRenderingContext/uniformMatrix) */
    uniformMatrix4fv(location: WebGLUniformLocation | null, transpose: GLboolean, data: Float32List, srcOffset?: number, srcLength?: GLuint): void;
}
