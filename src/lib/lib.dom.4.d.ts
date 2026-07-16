
/**
 * The **`Location`** interface represents the location (URL) of the object it is linked to. Changes done on it are reflected on the object it relates to. Both the Document and Window interface have such a linked Location, accessible via Document.location and Window.location respectively.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location)
 */
interface Location {
    /**
     * The **`ancestorOrigins`** read-only property of the Location interface is a static DOMStringList containing, in reverse order, the origins of all ancestor browsing contexts of the document associated with the given Location object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/ancestorOrigins)
     */
    readonly ancestorOrigins: DOMStringList;
    /**
     * The **`hash`** property of the Location interface is a string containing a "#" followed by the fragment identifier of the location URL. If the URL does not have a fragment identifier, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/hash)
     */
    hash: string;
    /**
     * The **`host`** property of the Location interface is a string containing the host, which is the hostname, and then, if the port of the URL is nonempty, a ":", followed by the port of the URL. If the URL does not have a hostname, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/host)
     */
    host: string;
    /**
     * The **`hostname`** property of the Location interface is a string containing either the domain name or IP address of the location URL. If the URL does not have a hostname, this property contains an empty string, "". IPv4 and IPv6 addresses are normalized, such as stripping leading zeros, and domain names are converted to IDN.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/hostname)
     */
    hostname: string;
    /**
     * The **`href`** property of the Location interface is a stringifier that returns a string containing the whole URL, and allows the href to be updated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/href)
     */
    href: string;
    toString(): string;
    /**
     * The **`origin`** read-only property of the Location interface returns a string containing the Unicode serialization of the origin of the location's URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/origin)
     */
    readonly origin: string;
    /**
     * The **`pathname`** property of the Location interface is a string containing the path of the URL for the location. If there is no path, pathname will be empty: otherwise, pathname contains an initial '/' followed by the path of the URL, not including the query string or fragment.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/pathname)
     */
    pathname: string;
    /**
     * The **`port`** property of the Location interface is a string containing the port number of the location's URL. If the port is the default for the protocol (80 for ws: and http:, 443 for wss: and https:, and 21 for ftp:), this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/port)
     */
    port: string;
    /**
     * The **`protocol`** property of the Location interface is a string containing the protocol or scheme of the location's URL, including the final ":".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/protocol)
     */
    protocol: string;
    /**
     * The **`search`** property of the Location interface is a search string, also called a query string, that is a string containing a "?" followed by the parameters of the location's URL. If the URL does not have a search query, this property contains an empty string, "".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/search)
     */
    search: string;
    /**
     * The **`assign()`** method of the Location interface causes the window to load and display the document at the URL specified. After the navigation occurs, the user can navigate back to the page that called Location.assign() by pressing the "back" button.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/assign)
     */
    assign(url: string | URL): void;
    /**
     * The **`reload()`** method of the Location interface reloads the current URL, like the Refresh button.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/reload)
     */
    reload(): void;
    /**
     * The **`replace()`** method of the Location interface replaces the current resource with the one at the provided URL. The difference from the assign() method is that after using replace() the current page will not be saved in session History, meaning the user won't be able to use the back button to navigate to it. Not to be confused with the String method String.prototype.replace().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Location/replace)
     */
    replace(url: string | URL): void;
}

declare var Location: {
    prototype: Location;
    new(): Location;
};

/**
 * The **`Lock`** interface of the Web Locks API provides the name and mode of a lock. This may be a newly requested lock that is received in the callback to LockManager.request(), or a record of an active or queued lock returned by LockManager.query().
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Lock)
 */
interface Lock {
    /**
     * The **`mode`** read-only property of the Lock interface returns the access mode passed to LockManager.request() when the lock was requested. The mode is either "exclusive" (the default) or "shared".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Lock/mode)
     */
    readonly mode: LockMode;
    /**
     * The **`name`** read-only property of the Lock interface returns the name passed to LockManager.request selected when the lock was requested.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Lock/name)
     */
    readonly name: string;
}

declare var Lock: {
    prototype: Lock;
    new(): Lock;
};

/**
 * The **`LockManager`** interface of the Web Locks API provides methods for requesting a new Lock object and querying for an existing Lock object. To get an instance of LockManager, call navigator.locks.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LockManager)
 */
interface LockManager {
    /**
     * The **`query()`** method of the LockManager interface returns a Promise that resolves with an object containing information about held and pending locks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LockManager/query)
     */
    query(): Promise<LockManagerSnapshot>;
    /**
     * The **`request()`** method of the LockManager interface requests a Lock object with parameters specifying its name and characteristics. The requested Lock is passed to a callback, while the function itself returns a Promise that resolves (or rejects) with the result of the callback after the lock is released, or rejects if the request is aborted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/LockManager/request)
     */
    request<T>(name: string, callback: LockGrantedCallback<T>): Promise<Awaited<T>>;
    request<T>(name: string, options: LockOptions, callback: LockGrantedCallback<T>): Promise<Awaited<T>>;
}

declare var LockManager: {
    prototype: LockManager;
    new(): LockManager;
};

interface MIDIAccessEventMap {
    "statechange": MIDIConnectionEvent;
}

/**
 * The **`MIDIAccess`** interface of the Web MIDI API provides methods for listing MIDI input and output devices, and obtaining access to those devices.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIAccess)
 */
interface MIDIAccess extends EventTarget {
    /**
     * The **`inputs`** read-only property of the MIDIAccess interface provides access to any available MIDI input ports.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIAccess/inputs)
     */
    readonly inputs: MIDIInputMap;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIAccess/statechange_event) */
    onstatechange: ((this: MIDIAccess, ev: MIDIConnectionEvent) => any) | null;
    /**
     * The **`outputs`** read-only property of the MIDIAccess interface provides access to any available MIDI output ports.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIAccess/outputs)
     */
    readonly outputs: MIDIOutputMap;
    /**
     * The **`sysexEnabled`** read-only property of the MIDIAccess interface indicates whether system exclusive support is enabled on the current MIDIAccess instance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIAccess/sysexEnabled)
     */
    readonly sysexEnabled: boolean;
    addEventListener<K extends keyof MIDIAccessEventMap>(type: K, listener: (this: MIDIAccess, ev: MIDIAccessEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MIDIAccessEventMap>(type: K, listener: (this: MIDIAccess, ev: MIDIAccessEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MIDIAccess: {
    prototype: MIDIAccess;
    new(): MIDIAccess;
};

/**
 * The **`MIDIConnectionEvent`** interface of the Web MIDI API is the event passed to the statechange event of the MIDIAccess interface and the statechange event of the MIDIPort interface. This occurs any time a new port becomes available, or when a previously available port becomes unavailable. For example, this event is fired whenever a MIDI device is either plugged in to or unplugged from a computer.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIConnectionEvent)
 */
interface MIDIConnectionEvent extends Event {
    /**
     * The **`port`** read-only property of the MIDIConnectionEvent interface returns the port that has been disconnected or connected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIConnectionEvent/port)
     */
    readonly port: MIDIPort | null;
}

declare var MIDIConnectionEvent: {
    prototype: MIDIConnectionEvent;
    new(type: string, eventInitDict?: MIDIConnectionEventInit): MIDIConnectionEvent;
};

interface MIDIInputEventMap extends MIDIPortEventMap {
    "midimessage": MIDIMessageEvent;
}

/**
 * The **`MIDIInput`** interface of the Web MIDI API receives messages from a MIDI input port.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIInput)
 */
interface MIDIInput extends MIDIPort {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIInput/midimessage_event) */
    onmidimessage: ((this: MIDIInput, ev: MIDIMessageEvent) => any) | null;
    addEventListener<K extends keyof MIDIInputEventMap>(type: K, listener: (this: MIDIInput, ev: MIDIInputEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MIDIInputEventMap>(type: K, listener: (this: MIDIInput, ev: MIDIInputEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MIDIInput: {
    prototype: MIDIInput;
    new(): MIDIInput;
};

/**
 * The **`MIDIInputMap`** read-only interface of the Web MIDI API provides the set of MIDI input ports that are currently available.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIInputMap)
 */
interface MIDIInputMap {
    forEach(callbackfn: (value: MIDIInput, key: string, parent: MIDIInputMap) => void, thisArg?: any): void;
}

declare var MIDIInputMap: {
    prototype: MIDIInputMap;
    new(): MIDIInputMap;
};

/**
 * The **`MIDIMessageEvent`** interface of the Web MIDI API represents the event passed to the midimessage event of the MIDIInput interface. A midimessage event is fired every time a MIDI message is sent from a device represented by a MIDIInput, for example when a MIDI keyboard key is pressed, a knob is tweaked, or a slider is moved.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIMessageEvent)
 */
interface MIDIMessageEvent extends Event {
    /**
     * The **`data`** read-only property of the MIDIMessageEvent interface returns the MIDI data bytes of a single MIDI message.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIMessageEvent/data)
     */
    readonly data: Uint8Array<ArrayBuffer> | null;
}

declare var MIDIMessageEvent: {
    prototype: MIDIMessageEvent;
    new(type: string, eventInitDict?: MIDIMessageEventInit): MIDIMessageEvent;
};

/**
 * The **`MIDIOutput`** interface of the Web MIDI API provides methods to add messages to the queue of an output device, and to clear the queue of messages.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIOutput)
 */
interface MIDIOutput extends MIDIPort {
    /**
     * The **`send()`** method of the MIDIOutput interface queues messages for the corresponding MIDI port. The message can be sent immediately, or with an optional timestamp to delay sending.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIOutput/send)
     */
    send(data: number[], timestamp?: DOMHighResTimeStamp): void;
    addEventListener<K extends keyof MIDIPortEventMap>(type: K, listener: (this: MIDIOutput, ev: MIDIPortEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MIDIPortEventMap>(type: K, listener: (this: MIDIOutput, ev: MIDIPortEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MIDIOutput: {
    prototype: MIDIOutput;
    new(): MIDIOutput;
};

/**
 * The **`MIDIOutputMap`** read-only interface of the Web MIDI API provides the set of MIDI output ports that are currently available.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIOutputMap)
 */
interface MIDIOutputMap {
    forEach(callbackfn: (value: MIDIOutput, key: string, parent: MIDIOutputMap) => void, thisArg?: any): void;
}

declare var MIDIOutputMap: {
    prototype: MIDIOutputMap;
    new(): MIDIOutputMap;
};

interface MIDIPortEventMap {
    "statechange": MIDIConnectionEvent;
}

/**
 * The **`MIDIPort`** interface of the Web MIDI API represents a MIDI input or output port.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort)
 */
interface MIDIPort extends EventTarget {
    /**
     * The **`connection`** read-only property of the MIDIPort interface returns the connection state of the port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/connection)
     */
    readonly connection: MIDIPortConnectionState;
    /**
     * The **`id`** read-only property of the MIDIPort interface returns the unique ID of the port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/id)
     */
    readonly id: string;
    /**
     * The **`manufacturer`** read-only property of the MIDIPort interface returns the manufacturer of the port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/manufacturer)
     */
    readonly manufacturer: string | null;
    /**
     * The **`name`** read-only property of the MIDIPort interface returns the system name of the port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/name)
     */
    readonly name: string | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/statechange_event) */
    onstatechange: ((this: MIDIPort, ev: MIDIConnectionEvent) => any) | null;
    /**
     * The **`state`** read-only property of the MIDIPort interface returns the state of the port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/state)
     */
    readonly state: MIDIPortDeviceState;
    /**
     * The **`type`** read-only property of the MIDIPort interface returns the type of the port, indicating whether this is an input or output MIDI port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/type)
     */
    readonly type: MIDIPortType;
    /**
     * The **`version`** read-only property of the MIDIPort interface returns the version of the port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/version)
     */
    readonly version: string | null;
    /**
     * The **`close()`** method of the MIDIPort interface makes the access to the MIDI device connected to this MIDIPort unavailable.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/close)
     */
    close(): Promise<MIDIPort>;
    /**
     * The **`open()`** method of the MIDIPort interface makes the MIDI device connected to this MIDIPort explicitly available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MIDIPort/open)
     */
    open(): Promise<MIDIPort>;
    addEventListener<K extends keyof MIDIPortEventMap>(type: K, listener: (this: MIDIPort, ev: MIDIPortEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MIDIPortEventMap>(type: K, listener: (this: MIDIPort, ev: MIDIPortEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MIDIPort: {
    prototype: MIDIPort;
    new(): MIDIPort;
};

interface MathMLElementEventMap extends ElementEventMap, GlobalEventHandlersEventMap {
}

/**
 * The **`MathMLElement`** interface represents any MathML element.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MathMLElement)
 */
interface MathMLElement extends Element, ElementCSSInlineStyle, GlobalEventHandlers, HTMLOrSVGElement {
    addEventListener<K extends keyof MathMLElementEventMap>(type: K, listener: (this: MathMLElement, ev: MathMLElementEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MathMLElementEventMap>(type: K, listener: (this: MathMLElement, ev: MathMLElementEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MathMLElement: {
    prototype: MathMLElement;
    new(): MathMLElement;
};

/**
 * The **`MediaCapabilities`** interface of the Media Capabilities API provides information about the decoding abilities of the device, system and browser. The API can be used to query the browser about the decoding abilities of the device based on codecs, profile, resolution, and bitrates. The information can be used to serve optimal media streams to the user and determine if playback should be smooth and power efficient.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaCapabilities)
 */
interface MediaCapabilities {
    /**
     * The **`decodingInfo()`** method of the MediaCapabilities interface returns a promise that fulfils with information about how well the user agent can decode/display media with a given configuration.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaCapabilities/decodingInfo)
     */
    decodingInfo(configuration: MediaDecodingConfiguration): Promise<MediaCapabilitiesDecodingInfo>;
    /**
     * The **`encodingInfo()`** method of the MediaCapabilities interface returns a promise that fulfills with the tested media configuration's capabilities for encoding media. This contains the three boolean properties supported, smooth, and powerefficient, which describe how compatible the device is with the type of media.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaCapabilities/encodingInfo)
     */
    encodingInfo(configuration: MediaEncodingConfiguration): Promise<MediaCapabilitiesEncodingInfo>;
}

declare var MediaCapabilities: {
    prototype: MediaCapabilities;
    new(): MediaCapabilities;
};

/**
 * The **`MediaDeviceInfo`** interface of the Media Capture and Streams API contains information that describes a single media input or output device.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDeviceInfo)
 */
interface MediaDeviceInfo {
    /**
     * The **`deviceId`** read-only property of the MediaDeviceInfo interface returns a string that is an identifier for the represented device and is persisted across sessions.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDeviceInfo/deviceId)
     */
    readonly deviceId: string;
    /**
     * The **`groupId`** read-only property of the MediaDeviceInfo interface returns a string that is a group identifier.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDeviceInfo/groupId)
     */
    readonly groupId: string;
    /**
     * The **`kind`** read-only property of the MediaDeviceInfo interface returns an enumerated value, that is either "videoinput", "audioinput" or "audiooutput".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDeviceInfo/kind)
     */
    readonly kind: MediaDeviceKind;
    /**
     * The **`label`** read-only property of the MediaDeviceInfo interface returns a string describing this device (for example "External USB Webcam").
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDeviceInfo/label)
     */
    readonly label: string;
    /**
     * The **`toJSON()`** method of the MediaDeviceInfo interface is a serializer; it returns a JSON representation of the MediaDeviceInfo object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDeviceInfo/toJSON)
     */
    toJSON(): any;
}

declare var MediaDeviceInfo: {
    prototype: MediaDeviceInfo;
    new(): MediaDeviceInfo;
};

interface MediaDevicesEventMap {
    "devicechange": Event;
}

/**
 * The **`MediaDevices`** interface of the Media Capture and Streams API provides access to connected media input devices like cameras and microphones, as well as screen sharing. In essence, it lets you obtain access to any hardware source of media data.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDevices)
 */
interface MediaDevices extends EventTarget {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDevices/devicechange_event) */
    ondevicechange: ((this: MediaDevices, ev: Event) => any) | null;
    /**
     * The **`enumerateDevices()`** method of the MediaDevices interface requests a list of the currently available media input and output devices, such as microphones, cameras, headsets, and so forth. The returned Promise is resolved with an array of MediaDeviceInfo objects describing the devices.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDevices/enumerateDevices)
     */
    enumerateDevices(): Promise<MediaDeviceInfo[]>;
    /**
     * The **`getDisplayMedia()`** method of the MediaDevices interface prompts the user to select and grant permission to capture the contents of a display or portion thereof (such as a window) as a MediaStream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDevices/getDisplayMedia)
     */
    getDisplayMedia(options?: DisplayMediaStreamOptions): Promise<MediaStream>;
    /**
     * The **`getSupportedConstraints()`** method of the MediaDevices interface returns an object based on the MediaTrackSupportedConstraints dictionary, whose member fields each specify one of the constrainable properties the user agent understands.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDevices/getSupportedConstraints)
     */
    getSupportedConstraints(): MediaTrackSupportedConstraints;
    /**
     * The **`getUserMedia()`** method of the MediaDevices interface prompts the user for permission to use a media input which produces a MediaStream with tracks containing the requested types of media.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaDevices/getUserMedia)
     */
    getUserMedia(constraints?: MediaStreamConstraints): Promise<MediaStream>;
    addEventListener<K extends keyof MediaDevicesEventMap>(type: K, listener: (this: MediaDevices, ev: MediaDevicesEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaDevicesEventMap>(type: K, listener: (this: MediaDevices, ev: MediaDevicesEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaDevices: {
    prototype: MediaDevices;
    new(): MediaDevices;
};

/**
 * The **`MediaElementAudioSourceNode`** interface represents an audio source consisting of an HTML <audio> or <video> element. It is an AudioNode that acts as an audio source.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaElementAudioSourceNode)
 */
interface MediaElementAudioSourceNode extends AudioNode {
    /**
     * The MediaElementAudioSourceNode interface's read-only **`mediaElement`** property indicates the HTMLMediaElement that contains the audio track from which the node is receiving audio.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaElementAudioSourceNode/mediaElement)
     */
    readonly mediaElement: HTMLMediaElement;
}

declare var MediaElementAudioSourceNode: {
    prototype: MediaElementAudioSourceNode;
    new(context: AudioContext, options: MediaElementAudioSourceOptions): MediaElementAudioSourceNode;
};

/**
 * The **`MediaEncryptedEvent`** interface of the Encrypted Media Extensions API contains the information associated with an encrypted event sent to a HTMLMediaElement when some initialization data is encountered in the media.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaEncryptedEvent)
 */
interface MediaEncryptedEvent extends Event {
    /**
     * The read-only **`initData`** property of the MediaKeyMessageEvent returns the initialization data contained in this event, if any.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaEncryptedEvent/initData)
     */
    readonly initData: ArrayBuffer | null;
    /**
     * The read-only **`initDataType`** property of the MediaKeyMessageEvent returns a case-sensitive string describing the type of the initialization data associated with this event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaEncryptedEvent/initDataType)
     */
    readonly initDataType: string;
}

declare var MediaEncryptedEvent: {
    prototype: MediaEncryptedEvent;
    new(type: string, eventInitDict?: MediaEncryptedEventInit): MediaEncryptedEvent;
};

/**
 * The **`MediaError`** interface represents an error which occurred while handling media in an HTML media element based on HTMLMediaElement, such as <audio> or <video>.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaError)
 */
interface MediaError {
    /**
     * The read-only property **`MediaError.code`** returns a numeric value which represents the kind of error that occurred on a media element. To get a text string with specific diagnostic information, see MediaError.message.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaError/code)
     */
    readonly code: number;
    /**
     * The read-only property **`MediaError.message`** returns a human-readable string offering specific diagnostic details related to the error described by the MediaError object, or an empty string ("") if no diagnostic information can be determined or provided.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaError/message)
     */
    readonly message: string;
    readonly MEDIA_ERR_ABORTED: 1;
    readonly MEDIA_ERR_NETWORK: 2;
    readonly MEDIA_ERR_DECODE: 3;
    readonly MEDIA_ERR_SRC_NOT_SUPPORTED: 4;
}

declare var MediaError: {
    prototype: MediaError;
    new(): MediaError;
    readonly MEDIA_ERR_ABORTED: 1;
    readonly MEDIA_ERR_NETWORK: 2;
    readonly MEDIA_ERR_DECODE: 3;
    readonly MEDIA_ERR_SRC_NOT_SUPPORTED: 4;
};

/**
 * The **`MediaKeyMessageEvent`** interface of the Encrypted Media Extensions API contains the content and related data when the content decryption module generates a message for the session.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyMessageEvent)
 */
interface MediaKeyMessageEvent extends Event {
    /**
     * The **`MediaKeyMessageEvent.message`** read-only property returns an ArrayBuffer with a message from the content decryption module. Messages vary by key system.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyMessageEvent/message)
     */
    readonly message: ArrayBuffer;
    /**
     * The **`MediaKeyMessageEvent.messageType`** read-only property indicates the type of message. It may be one of license-request, license-renewal, license-release, or individualization-request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyMessageEvent/messageType)
     */
    readonly messageType: MediaKeyMessageType;
}

declare var MediaKeyMessageEvent: {
    prototype: MediaKeyMessageEvent;
    new(type: string, eventInitDict: MediaKeyMessageEventInit): MediaKeyMessageEvent;
};

interface MediaKeySessionEventMap {
    "keystatuseschange": Event;
    "message": MediaKeyMessageEvent;
}

/**
 * The **`MediaKeySession`** interface of the Encrypted Media Extensions API represents a context for message exchange with a content decryption module (CDM).
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession)
 */
interface MediaKeySession extends EventTarget {
    /**
     * The **`closed`** read-only property of the MediaKeySession interface returns a Promise signaling when a MediaKeySession closes. This promise can only be fulfilled and is never rejected. Closing a session means that licenses and keys associated with it are no longer valid for decrypting media data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/closed)
     */
    readonly closed: Promise<MediaKeySessionClosedReason>;
    /**
     * The **`expiration`** read-only property of the MediaKeySession interface returns the time after which the keys in the current session can no longer be used to decrypt media data, or NaN if no such time exists.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/expiration)
     */
    readonly expiration: number;
    /**
     * The **`keyStatuses`** read-only property of the MediaKeySession interface returns a reference to a read-only MediaKeyStatusMap of the current session's keys and their statuses.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/keyStatuses)
     */
    readonly keyStatuses: MediaKeyStatusMap;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/keystatuseschange_event) */
    onkeystatuseschange: ((this: MediaKeySession, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/message_event) */
    onmessage: ((this: MediaKeySession, ev: MediaKeyMessageEvent) => any) | null;
    /**
     * The **`sessionId`** read-only property of the MediaKeySession interface contains a unique string generated by the content decryption module (CDM) for the current media object and its associated keys or licenses.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/sessionId)
     */
    readonly sessionId: string;
    /**
     * The **`close()`** method of the MediaKeySession interface notifies that the current media session is no longer needed, and that the content decryption module should release any resources associated with this object and close it. Then, it returns a Promise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/close)
     */
    close(): Promise<void>;
    /**
     * The **`generateRequest()`** method of the MediaKeySession interface returns a Promise after generating a license request based on initialization data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/generateRequest)
     */
    generateRequest(initDataType: string, initData: BufferSource): Promise<void>;
    /**
     * The **`load()`** method of the MediaKeySession interface returns a Promise that resolves to a boolean value after loading data for a specified session object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/load)
     */
    load(sessionId: string): Promise<boolean>;
    /**
     * The **`remove()`** method of the MediaKeySession interface returns a Promise after removing any session data associated with the current object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/remove)
     */
    remove(): Promise<void>;
    /**
     * The **`update()`** method of the MediaKeySession interface loads messages and licenses to the CDM, and then returns a Promise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySession/update)
     */
    update(response: BufferSource): Promise<void>;
    addEventListener<K extends keyof MediaKeySessionEventMap>(type: K, listener: (this: MediaKeySession, ev: MediaKeySessionEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaKeySessionEventMap>(type: K, listener: (this: MediaKeySession, ev: MediaKeySessionEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaKeySession: {
    prototype: MediaKeySession;
    new(): MediaKeySession;
};

/**
 * The **`MediaKeyStatusMap`** interface of the Encrypted Media Extensions API is a read-only map of media key statuses by key IDs.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyStatusMap)
 */
interface MediaKeyStatusMap {
    /**
     * The **`size`** read-only property of the MediaKeyStatusMap interface returns the number of key/value paIrs in the status map.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyStatusMap/size)
     */
    readonly size: number;
    /**
     * The **`get()`** method of the MediaKeyStatusMap interface returns the status value associated with the given key, or undefined if there is none.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyStatusMap/get)
     */
    get(keyId: BufferSource): MediaKeyStatus | undefined;
    /**
     * The **`has()`** method of the MediaKeyStatusMap interface returns a Boolean, asserting whether a value has been associated with the given key.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeyStatusMap/has)
     */
    has(keyId: BufferSource): boolean;
    forEach(callbackfn: (value: MediaKeyStatus, key: BufferSource, parent: MediaKeyStatusMap) => void, thisArg?: any): void;
}

declare var MediaKeyStatusMap: {
    prototype: MediaKeyStatusMap;
    new(): MediaKeyStatusMap;
};

/**
 * The **`MediaKeySystemAccess`** interface of the Encrypted Media Extensions API provides access to a Key System for decryption and/or a content protection provider. You can request an instance of this object using the Navigator.requestMediaKeySystemAccess() method.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySystemAccess)
 */
interface MediaKeySystemAccess {
    /**
     * The **`keySystem`** read-only property of the MediaKeySystemAccess interface returns a string identifying the key system being used.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySystemAccess/keySystem)
     */
    readonly keySystem: string;
    /**
     * The **`MediaKeySystemAccess.createMediaKeys()`** method returns a Promise that resolves to a new MediaKeys object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySystemAccess/createMediaKeys)
     */
    createMediaKeys(): Promise<MediaKeys>;
    /**
     * The **`getConfiguration()`** method of the MediaKeySystemAccess interface returns an object with the supported combination of the following configuration options:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeySystemAccess/getConfiguration)
     */
    getConfiguration(): MediaKeySystemConfiguration;
}

declare var MediaKeySystemAccess: {
    prototype: MediaKeySystemAccess;
    new(): MediaKeySystemAccess;
};

/**
 * The **`MediaKeys`** interface of Encrypted Media Extensions API represents a set of keys that an associated HTMLMediaElement can use for decryption of media data during playback.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeys)
 */
interface MediaKeys {
    /**
     * The **`createSession()`** method of the MediaKeys interface returns a new MediaKeySession object, which represents a context for message exchange with a content decryption module (CDM).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeys/createSession)
     */
    createSession(sessionType?: MediaKeySessionType): MediaKeySession;
    /**
     * The **`getStatusForPolicy()`** method of the MediaKeys interface is used to check whether the Content Decryption Module (CDM) would allow the presentation of encrypted media data using the keys, based on the specified policy requirements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeys/getStatusForPolicy)
     */
    getStatusForPolicy(policy?: MediaKeysPolicy): Promise<MediaKeyStatus>;
    /**
     * The **`setServerCertificate()`** method of the MediaKeys interface provides a server certificate to be used to encrypt messages to the license server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaKeys/setServerCertificate)
     */
    setServerCertificate(serverCertificate: BufferSource): Promise<boolean>;
}

declare var MediaKeys: {
    prototype: MediaKeys;
    new(): MediaKeys;
};

/**
 * The **`MediaList`** interface represents the media queries of a stylesheet, e.g., those set using a <link> element's media attribute.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaList)
 */
interface MediaList {
    /**
     * The read-only **`length`** property of the MediaList interface returns the number of media queries in the list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaList/length)
     */
    readonly length: number;
    /**
     * The **`mediaText`** property of the MediaList interface is a stringifier that returns a string representing the MediaList as text, and also allows you to set a new MediaList.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaList/mediaText)
     */
    mediaText: string;
    toString(): string;
    /**
     * The **`appendMedium()`** method of the MediaList interface adds a media query to the list. If the media query is already in the collection, this method does nothing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaList/appendMedium)
     */
    appendMedium(medium: string): void;
    /**
     * The **`deleteMedium()`** method of the MediaList interface removes from this MediaList the given media query.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaList/deleteMedium)
     */
    deleteMedium(medium: string): void;
    /**
     * The **`item()`** method of the MediaList interface returns the media query at the specified index, or null if the specified index doesn't exist.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaList/item)
     */
    item(index: number): string | null;
    [index: number]: string;
}

declare var MediaList: {
    prototype: MediaList;
    new(): MediaList;
};

/**
 * The **`MediaMetadata`** interface of the Media Session API allows a web page to provide rich media metadata for display in a platform UI.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaMetadata)
 */
interface MediaMetadata {
    /**
     * The **`album`** property of the MediaMetadata interface returns or sets the name of the album or collection containing the media to be played.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaMetadata/album)
     */
    album: string;
    /**
     * The **`artist`** property of the MediaMetadata interface returns or sets the name of the artist, group, creator, etc., of the media to be played.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaMetadata/artist)
     */
    artist: string;
    /**
     * The **`artwork`** property of the MediaMetadata interface returns or sets an array of objects representing images associated with playing media.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaMetadata/artwork)
     */
    artwork: ReadonlyArray<MediaImage>;
    /**
     * The **`title`** property of the MediaMetadata interface returns or sets the title of the media to be played.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaMetadata/title)
     */
    title: string;
}

declare var MediaMetadata: {
    prototype: MediaMetadata;
    new(init?: MediaMetadataInit): MediaMetadata;
};

interface MediaQueryListEventMap {
    "change": MediaQueryListEvent;
}

/**
 * A **`MediaQueryList`** object stores information on a media query applied to a document, with support for both immediate and event-driven matching against the state of the document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryList)
 */
interface MediaQueryList extends EventTarget {
    /**
     * The **`matches`** read-only property of the MediaQueryList interface is a boolean value that returns true if the document currently matches the media query list, or false if not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryList/matches)
     */
    readonly matches: boolean;
    /**
     * The **`media`** read-only property of the MediaQueryList interface is a string representing a serialized media query.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryList/media)
     */
    readonly media: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryList/change_event) */
    onchange: ((this: MediaQueryList, ev: MediaQueryListEvent) => any) | null;
    /**
     * The deprecated **`addListener()`** method of the MediaQueryList interface adds a listener to the MediaQueryListener that will run a custom callback function in response to the media query status changing.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryList/addListener)
     */
    addListener(callback: ((this: MediaQueryList, ev: MediaQueryListEvent) => any) | null): void;
    /**
     * The **`removeListener()`** method of the MediaQueryList interface removes a listener from the MediaQueryListener.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryList/removeListener)
     */
    removeListener(callback: ((this: MediaQueryList, ev: MediaQueryListEvent) => any) | null): void;
    addEventListener<K extends keyof MediaQueryListEventMap>(type: K, listener: (this: MediaQueryList, ev: MediaQueryListEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaQueryListEventMap>(type: K, listener: (this: MediaQueryList, ev: MediaQueryListEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaQueryList: {
    prototype: MediaQueryList;
    new(): MediaQueryList;
};

/**
 * The **`MediaQueryListEvent`** object stores information on the changes that have happened to a MediaQueryList object — instances are available as the event object on a function referenced by a change event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryListEvent)
 */
interface MediaQueryListEvent extends Event {
    /**
     * The **`matches`** read-only property of the MediaQueryListEvent interface is a boolean value that is true if the document currently matches the media query list, or false if not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryListEvent/matches)
     */
    readonly matches: boolean;
    /**
     * The **`media`** read-only property of the MediaQueryListEvent interface is a string representing a serialized media query.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaQueryListEvent/media)
     */
    readonly media: string;
}

declare var MediaQueryListEvent: {
    prototype: MediaQueryListEvent;
    new(type: string, eventInitDict?: MediaQueryListEventInit): MediaQueryListEvent;
};

interface MediaRecorderEventMap {
    "dataavailable": BlobEvent;
    "error": ErrorEvent;
    "pause": Event;
    "resume": Event;
    "start": Event;
    "stop": Event;
}

/**
 * The **`MediaRecorder`** interface of the MediaStream Recording API provides functionality to easily record media. It is created using the MediaRecorder() constructor.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder)
 */
interface MediaRecorder extends EventTarget {
    /**
     * The **`audioBitsPerSecond`** read-only property of the MediaRecorder interface returns the audio encoding bit rate in use.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/audioBitsPerSecond)
     */
    readonly audioBitsPerSecond: number;
    /**
     * The **`mimeType`** read-only property of the MediaRecorder interface returns the MIME media type that was specified when creating the MediaRecorder object, or, if none was specified, which was chosen by the browser. This is the file format of the file that would result from writing all of the recorded data to disk.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/mimeType)
     */
    readonly mimeType: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/dataavailable_event) */
    ondataavailable: ((this: MediaRecorder, ev: BlobEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/error_event) */
    onerror: ((this: MediaRecorder, ev: ErrorEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/pause_event) */
    onpause: ((this: MediaRecorder, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/resume_event) */
    onresume: ((this: MediaRecorder, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/start_event) */
    onstart: ((this: MediaRecorder, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/stop_event) */
    onstop: ((this: MediaRecorder, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the MediaRecorder interface returns the current state of the current MediaRecorder object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/state)
     */
    readonly state: RecordingState;
    /**
     * The **`stream`** read-only property of the MediaRecorder interface returns the stream that was passed into the MediaRecorder() constructor when the MediaRecorder was created.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/stream)
     */
    readonly stream: MediaStream;
    /**
     * The **`videoBitsPerSecond`** read-only property of the MediaRecorder interface returns the video encoding bit rate in use.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/videoBitsPerSecond)
     */
    readonly videoBitsPerSecond: number;
    /**
     * The **`pause()`** method of the MediaRecorder interface is used to pause recording of media streams.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/pause)
     */
    pause(): void;
    /**
     * The **`requestData()`** method of the MediaRecorder interface is used to raise a dataavailable event containing a Blob object of the captured media as it was when the method was called. This can then be grabbed and manipulated as you wish.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/requestData)
     */
    requestData(): void;
    /**
     * The **`resume()`** method of the MediaRecorder interface is used to resume media recording when it has been previously paused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/resume)
     */
    resume(): void;
    /**
     * The **`start()`** method of the MediaRecorder interface begins recording media into one or more Blob objects.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/start)
     */
    start(timeslice?: number): void;
    /**
     * The **`stop()`** method of the MediaRecorder interface is used to stop media capture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/stop)
     */
    stop(): void;
    addEventListener<K extends keyof MediaRecorderEventMap>(type: K, listener: (this: MediaRecorder, ev: MediaRecorderEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaRecorderEventMap>(type: K, listener: (this: MediaRecorder, ev: MediaRecorderEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaRecorder: {
    prototype: MediaRecorder;
    new(stream: MediaStream, options?: MediaRecorderOptions): MediaRecorder;
    /**
     * The **`isTypeSupported()`** static method of the MediaRecorder interface returns a Boolean which is true if the MIME media type specified is one the user agent should be able to successfully record.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaRecorder/isTypeSupported_static)
     */
    isTypeSupported(type: string): boolean;
};

/**
 * The **`MediaSession`** interface of the Media Session API allows a web page to provide custom behaviors for standard media playback interactions, and to report metadata that can be sent by the user agent to the device or operating system for presentation in standardized user interface elements.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession)
 */
interface MediaSession {
    /**
     * The **`metadata`** property of the MediaSession interface contains a MediaMetadata object providing descriptive information about the currently playing media, or null if the metadata has not been set. This metadata is provided by the browser to the device for presentation in any standard media control user interface the device might offer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession/metadata)
     */
    metadata: MediaMetadata | null;
    /**
     * The **`playbackState`** property of the MediaSession interface indicates whether the current media session is playing or paused.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession/playbackState)
     */
    playbackState: MediaSessionPlaybackState;
    /**
     * The **`setActionHandler()`** method of the MediaSession interface sets a handler for a media session action. These actions let a web app receive notifications when the user engages a device's built-in physical or onscreen media controls, such as play, stop, or seek buttons.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession/setActionHandler)
     */
    setActionHandler(action: MediaSessionAction, handler: MediaSessionActionHandler | null): void;
    /**
     * The **`setCameraActive()`** method of the MediaSession interface is used to indicate to the user agent whether the user's camera is considered to be active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession/setCameraActive)
     */
    setCameraActive(active: boolean): Promise<void>;
    /**
     * The **`setMicrophoneActive()`** method of the MediaSession interface is used to indicate to the user agent whether the user's microphone is considered to be currently muted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession/setMicrophoneActive)
     */
    setMicrophoneActive(active: boolean): Promise<void>;
    /**
     * The **`setPositionState()`** method of the MediaSession interface is used to update the current document's media playback position and speed for presentation by user's device in any kind of interface that provides details about ongoing media. This can be particularly useful if your code implements a player for type of media not directly supported by the browser.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSession/setPositionState)
     */
    setPositionState(state?: MediaPositionState): void;
}

declare var MediaSession: {
    prototype: MediaSession;
    new(): MediaSession;
};

interface MediaSourceEventMap {
    "sourceclose": Event;
    "sourceended": Event;
    "sourceopen": Event;
}

/**
 * The **`MediaSource`** interface of the Media Source Extensions API represents a source of media data for an HTMLMediaElement object. A MediaSource object can be attached to a HTMLMediaElement to be played in the user agent.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource)
 */
interface MediaSource extends EventTarget {
    /**
     * The **`activeSourceBuffers`** read-only property of the MediaSource interface returns a SourceBufferList object containing a subset of the SourceBuffer objects contained within sourceBuffers — the list of objects providing the selected video track, enabled audio tracks, and shown/hidden text tracks.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/activeSourceBuffers)
     */
    readonly activeSourceBuffers: SourceBufferList;
    /**
     * The **`duration`** property of the MediaSource interface gets and sets the duration of the current media being presented.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/duration)
     */
    duration: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/sourceclose_event) */
    onsourceclose: ((this: MediaSource, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/sourceended_event) */
    onsourceended: ((this: MediaSource, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/sourceopen_event) */
    onsourceopen: ((this: MediaSource, ev: Event) => any) | null;
    /**
     * The **`readyState`** read-only property of the MediaSource interface returns an enum representing the state of the current MediaSource. The three possible values are:
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/readyState)
     */
    readonly readyState: ReadyState;
    /**
     * The **`sourceBuffers`** read-only property of the MediaSource interface returns a SourceBufferList object containing the list of SourceBuffer objects associated with this MediaSource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/sourceBuffers)
     */
    readonly sourceBuffers: SourceBufferList;
    /**
     * The **`addSourceBuffer()`** method of the MediaSource interface creates a new SourceBuffer of the given MIME type and adds it to the MediaSource's sourceBuffers list. The new SourceBuffer is also returned.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/addSourceBuffer)
     */
    addSourceBuffer(type: string): SourceBuffer;
    /**
     * The **`clearLiveSeekableRange()`** method of the MediaSource interface clears a seekable range previously set with a call to setLiveSeekableRange().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/clearLiveSeekableRange)
     */
    clearLiveSeekableRange(): void;
    /**
     * The **`endOfStream()`** method of the MediaSource interface signals the end of the stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/endOfStream)
     */
    endOfStream(error?: EndOfStreamError): void;
    /**
     * The **`removeSourceBuffer()`** method of the MediaSource interface removes the given SourceBuffer from the SourceBufferList associated with this MediaSource object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/removeSourceBuffer)
     */
    removeSourceBuffer(sourceBuffer: SourceBuffer): void;
    /**
     * The **`setLiveSeekableRange()`** method of the MediaSource interface sets the range that the user can seek to in the media element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/setLiveSeekableRange)
     */
    setLiveSeekableRange(start: number, end: number): void;
    addEventListener<K extends keyof MediaSourceEventMap>(type: K, listener: (this: MediaSource, ev: MediaSourceEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaSourceEventMap>(type: K, listener: (this: MediaSource, ev: MediaSourceEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaSource: {
    prototype: MediaSource;
    new(): MediaSource;
    /**
     * The **`canConstructInDedicatedWorker`** static property of the MediaSource interface returns true if MediaSource worker support is implemented, providing a low-latency feature detection mechanism.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/canConstructInDedicatedWorker_static)
     */
    readonly canConstructInDedicatedWorker: boolean;
    /**
     * The **`MediaSource.isTypeSupported()`** static method returns a boolean value which is true if the given MIME type and (optional) codec are likely to be supported by the current user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSource/isTypeSupported_static)
     */
    isTypeSupported(type: string): boolean;
};

/**
 * The **`MediaSourceHandle`** interface of the Media Source Extensions API is a proxy for a MediaSource that can be transferred from a dedicated worker back to the main thread and attached to a media element via its HTMLMediaElement.srcObject property. MediaSource objects are not transferable because they are event targets, hence the need for MediaSourceHandles.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaSourceHandle)
 */
interface MediaSourceHandle {
}

declare var MediaSourceHandle: {
    prototype: MediaSourceHandle;
    new(): MediaSourceHandle;
};

interface MediaStreamEventMap {
    "addtrack": MediaStreamTrackEvent;
    "removetrack": MediaStreamTrackEvent;
}

/**
 * The **`MediaStream`** interface of the Media Capture and Streams API represents a stream of media content. A stream consists of several tracks, such as video or audio tracks. Each track is specified as an instance of MediaStreamTrack.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream)
 */
interface MediaStream extends EventTarget {
    /**
     * The **`active`** read-only property of the MediaStream interface returns a Boolean value which is true if the stream is currently active; otherwise, it returns false. A stream is considered active if at least one of its MediaStreamTracks does not have its property MediaStreamTrack.readyState set to ended. Once every track has ended, the stream's active property becomes false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/active)
     */
    readonly active: boolean;
    /**
     * The **`id`** read-only property of the MediaStream interface is a string containing 36 characters denoting a unique identifier (GUID) for the object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/id)
     */
    readonly id: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/addtrack_event) */
    onaddtrack: ((this: MediaStream, ev: MediaStreamTrackEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/removetrack_event) */
    onremovetrack: ((this: MediaStream, ev: MediaStreamTrackEvent) => any) | null;
    /**
     * The **`addTrack()`** method of the MediaStream interface adds a new track to the stream. The track is specified as a parameter of type MediaStreamTrack.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/addTrack)
     */
    addTrack(track: MediaStreamTrack): void;
    /**
     * The **`clone()`** method of the MediaStream interface creates a duplicate of the MediaStream. This new MediaStream object has a new unique id and contains clones of every MediaStreamTrack contained by the MediaStream on which clone() was called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/clone)
     */
    clone(): MediaStream;
    /**
     * The **`getAudioTracks()`** method of the MediaStream interface returns a sequence that represents all the MediaStreamTrack objects in this stream's track set where MediaStreamTrack.kind is audio.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/getAudioTracks)
     */
    getAudioTracks(): MediaStreamTrack[];
    /**
     * The **`getTrackById()`** method of the MediaStream interface returns a MediaStreamTrack object representing the track with the specified ID string. If there is no track with the specified ID, this method returns null.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/getTrackById)
     */
    getTrackById(trackId: string): MediaStreamTrack | null;
    /**
     * The **`getTracks()`** method of the MediaStream interface returns a sequence that represents all the MediaStreamTrack objects in this stream's track set, regardless of MediaStreamTrack.kind.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/getTracks)
     */
    getTracks(): MediaStreamTrack[];
    /**
     * The **`getVideoTracks()`** method of the MediaStream interface returns a sequence of MediaStreamTrack objects representing the video tracks in this stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/getVideoTracks)
     */
    getVideoTracks(): MediaStreamTrack[];
    /**
     * The **`removeTrack()`** method of the MediaStream interface removes a MediaStreamTrack from a stream.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStream/removeTrack)
     */
    removeTrack(track: MediaStreamTrack): void;
    addEventListener<K extends keyof MediaStreamEventMap>(type: K, listener: (this: MediaStream, ev: MediaStreamEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaStreamEventMap>(type: K, listener: (this: MediaStream, ev: MediaStreamEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaStream: {
    prototype: MediaStream;
    new(): MediaStream;
    new(stream: MediaStream): MediaStream;
    new(tracks: MediaStreamTrack[]): MediaStream;
};

/**
 * The **`MediaStreamAudioDestinationNode`** interface represents an audio destination consisting of a WebRTC MediaStream with a single AudioMediaStreamTrack, which can be used in a similar way to a MediaStream obtained from navigator.mediaDevices.getUserMedia().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamAudioDestinationNode)
 */
interface MediaStreamAudioDestinationNode extends AudioNode {
    /**
     * The **`stream`** property of the AudioContext interface represents a MediaStream containing a single audio MediaStreamTrack with the same number of channels as the node itself.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamAudioDestinationNode/stream)
     */
    readonly stream: MediaStream;
}

declare var MediaStreamAudioDestinationNode: {
    prototype: MediaStreamAudioDestinationNode;
    new(context: AudioContext, options?: AudioNodeOptions): MediaStreamAudioDestinationNode;
};

/**
 * The **`MediaStreamAudioSourceNode`** interface is a type of AudioNode which operates as an audio source whose media is received from a MediaStream obtained using the WebRTC or Media Capture and Streams APIs.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamAudioSourceNode)
 */
interface MediaStreamAudioSourceNode extends AudioNode {
    /**
     * The MediaStreamAudioSourceNode interface's read-only **`mediaStream`** property indicates the MediaStream that contains the audio track from which the node is receiving audio.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamAudioSourceNode/mediaStream)
     */
    readonly mediaStream: MediaStream;
}

declare var MediaStreamAudioSourceNode: {
    prototype: MediaStreamAudioSourceNode;
    new(context: AudioContext, options: MediaStreamAudioSourceOptions): MediaStreamAudioSourceNode;
};

interface MediaStreamTrackEventMap {
    "ended": Event;
    "mute": Event;
    "unmute": Event;
}

/**
 * The **`MediaStreamTrack`** interface of the Media Capture and Streams API represents a single media track within a stream; typically, these are audio or video tracks, but other track types may exist as well.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack)
 */
interface MediaStreamTrack extends EventTarget {
    /**
     * The **`contentHint`** property of the MediaStreamTrack interface is a string that hints at the type of content the track contains. Allowable values depend on the value of the MediaStreamTrack.kind property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/contentHint)
     */
    contentHint: string;
    /**
     * The **`enabled`** property of the MediaStreamTrack interface is a Boolean value which is true if the track is allowed to render the source stream or false if it is not. This can be used to intentionally mute a track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/enabled)
     */
    enabled: boolean;
    /**
     * The **`id`** read-only property of the MediaStreamTrack interface returns a string containing a unique identifier (GUID) for the track, which is generated by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/id)
     */
    readonly id: string;
    /**
     * The **`kind`** read-only property of the MediaStreamTrack interface returns a string set to "audio" if the track is an audio track and to "video" if it is a video track. It doesn't change if the track is disassociated from its source.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/kind)
     */
    readonly kind: string;
    /**
     * The **`label`** read-only property of the MediaStreamTrack interface returns a string containing a user agent-assigned label that identifies the track source, as in "internal microphone".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/label)
     */
    readonly label: string;
    /**
     * The **`muted`** read-only property of the MediaStreamTrack interface returns a boolean value indicating whether or not the track is currently unable to provide media output.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/muted)
     */
    readonly muted: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/ended_event) */
    onended: ((this: MediaStreamTrack, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/mute_event) */
    onmute: ((this: MediaStreamTrack, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/unmute_event) */
    onunmute: ((this: MediaStreamTrack, ev: Event) => any) | null;
    /**
     * The **`readyState`** read-only property of the MediaStreamTrack interface returns an enumerated value giving the status of the track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/readyState)
     */
    readonly readyState: MediaStreamTrackState;
    /**
     * The **`applyConstraints()`** method of the MediaStreamTrack interface applies a set of constraints to the track; these constraints let the website or app establish ideal values and acceptable ranges of values for the constrainable properties of the track, such as frame rate, dimensions, echo cancellation, and so forth.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/applyConstraints)
     */
    applyConstraints(constraints?: MediaTrackConstraints): Promise<void>;
    /**
     * The **`clone()`** method of the MediaStreamTrack interface creates a duplicate of the MediaStreamTrack. This new MediaStreamTrack object is identical except for its unique id.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/clone)
     */
    clone(): MediaStreamTrack;
    /**
     * The **`getCapabilities()`** method of the MediaStreamTrack interface returns an object detailing the accepted values or value range for each constrainable property of the associated MediaStreamTrack, based upon the platform and user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/getCapabilities)
     */
    getCapabilities(): MediaTrackCapabilities;
    /**
     * The **`getConstraints()`** method of the MediaStreamTrack interface returns a MediaTrackConstraints object containing the set of constraints most recently established for the track using a prior call to applyConstraints(). These constraints indicate values and ranges of values that the website or application has specified are required or acceptable for the included constrainable properties.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/getConstraints)
     */
    getConstraints(): MediaTrackConstraints;
    /**
     * The **`getSettings()`** method of the MediaStreamTrack interface returns a MediaTrackSettings object containing the current values of each of the constrainable properties for the current MediaStreamTrack.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/getSettings)
     */
    getSettings(): MediaTrackSettings;
    /**
     * The **`stop()`** method of the MediaStreamTrack interface stops the track.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrack/stop)
     */
    stop(): void;
    addEventListener<K extends keyof MediaStreamTrackEventMap>(type: K, listener: (this: MediaStreamTrack, ev: MediaStreamTrackEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MediaStreamTrackEventMap>(type: K, listener: (this: MediaStreamTrack, ev: MediaStreamTrackEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MediaStreamTrack: {
    prototype: MediaStreamTrack;
    new(): MediaStreamTrack;
};

/**
 * The **`MediaStreamTrackEvent`** interface of the Media Capture and Streams API represents events which indicate that a MediaStream has had tracks added to or removed from the stream through calls to Media Capture and Streams API methods. These events are sent to the stream when these changes occur.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrackEvent)
 */
interface MediaStreamTrackEvent extends Event {
    /**
     * The **`track`** read-only property of the MediaStreamTrackEvent interface returns the MediaStreamTrack associated with this event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MediaStreamTrackEvent/track)
     */
    readonly track: MediaStreamTrack;
}

declare var MediaStreamTrackEvent: {
    prototype: MediaStreamTrackEvent;
    new(type: string, eventInitDict: MediaStreamTrackEventInit): MediaStreamTrackEvent;
};

/**
 * The **`MessageChannel`** interface of the Channel Messaging API allows us to create a new message channel and send data through it via its two MessagePort properties.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageChannel)
 */
interface MessageChannel {
    /**
     * The **`port1`** read-only property of the MessageChannel interface returns the first port of the message channel — the port attached to the context that originated the channel.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageChannel/port1)
     */
    readonly port1: MessagePort;
    /**
     * The **`port2`** read-only property of the MessageChannel interface returns the second port of the message channel — the port attached to the context at the other end of the channel, which the message is initially sent to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageChannel/port2)
     */
    readonly port2: MessagePort;
}

declare var MessageChannel: {
    prototype: MessageChannel;
    new(): MessageChannel;
};

/**
 * The **`MessageEvent`** interface represents a message received by a target object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageEvent)
 */
interface MessageEvent<T = any> extends Event {
    /**
     * The **`data`** read-only property of the MessageEvent interface represents the data sent by the message emitter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageEvent/data)
     */
    readonly data: T;
    /**
     * The **`lastEventId`** read-only property of the MessageEvent interface is a string representing a unique ID for the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageEvent/lastEventId)
     */
    readonly lastEventId: string;
    /**
     * The **`origin`** read-only property of the MessageEvent interface is a string representing the origin of the message emitter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageEvent/origin)
     */
    readonly origin: string;
    /**
     * The **`ports`** read-only property of the MessageEvent interface is an array of MessagePort objects containing all MessagePort objects sent with the message, in order.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageEvent/ports)
     */
    readonly ports: ReadonlyArray<MessagePort>;
    /**
     * The **`source`** read-only property of the MessageEvent interface is a MessageEventSource (which can be a WindowProxy, MessagePort, or ServiceWorker object) representing the message emitter.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessageEvent/source)
     */
    readonly source: MessageEventSource | null;
    /** @deprecated */
    initMessageEvent(type: string, bubbles?: boolean, cancelable?: boolean, data?: any, origin?: string, lastEventId?: string, source?: MessageEventSource | null, ports?: MessagePort[]): void;
}

declare var MessageEvent: {
    prototype: MessageEvent;
    new<T>(type: string, eventInitDict?: MessageEventInit<T>): MessageEvent<T>;
};

interface MessageEventTargetEventMap {
    "message": MessageEvent;
    "messageerror": MessageEvent;
}

interface MessageEventTarget<T> {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/DedicatedWorkerGlobalScope/message_event) */
    onmessage: ((this: T, ev: MessageEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/DedicatedWorkerGlobalScope/messageerror_event) */
    onmessageerror: ((this: T, ev: MessageEvent) => any) | null;
    addEventListener<K extends keyof MessageEventTargetEventMap>(type: K, listener: (this: T, ev: MessageEventTargetEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MessageEventTargetEventMap>(type: K, listener: (this: T, ev: MessageEventTargetEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

interface MessagePortEventMap extends MessageEventTargetEventMap {
    "message": MessageEvent;
    "messageerror": MessageEvent;
}

/**
 * The **`MessagePort`** interface of the Channel Messaging API represents one of the two ports of a MessageChannel, allowing messages to be sent from one port and listening out for them arriving at the other.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessagePort)
 */
interface MessagePort extends EventTarget, MessageEventTarget<MessagePort> {
    /**
     * The **`close()`** method of the MessagePort interface disconnects the port, so it is no longer active. This stops the flow of messages to that port.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessagePort/close)
     */
    close(): void;
    /**
     * The **`postMessage()`** method of the MessagePort interface sends a message from the port, and optionally, transfers ownership of objects to other browsing contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessagePort/postMessage)
     */
    postMessage(message: any, transfer: Transferable[]): void;
    postMessage(message: any, options?: StructuredSerializeOptions): void;
    /**
     * The **`start()`** method of the MessagePort interface starts the sending of messages queued on the port. This method is only needed when using EventTarget.addEventListener; it is implied when using onmessage.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MessagePort/start)
     */
    start(): void;
    addEventListener<K extends keyof MessagePortEventMap>(type: K, listener: (this: MessagePort, ev: MessagePortEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof MessagePortEventMap>(type: K, listener: (this: MessagePort, ev: MessagePortEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var MessagePort: {
    prototype: MessagePort;
    new(): MessagePort;
};

/**
 * The **`MimeType`** interface provides contains information about a MIME type associated with a particular plugin. Navigator.mimeTypes returns an array of this object.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MimeType)
 */
interface MimeType {
    /**
     * Returns the MIME type's description.
     * @deprecated
     */
    readonly description: string;
    /**
     * Returns the Plugin object that implements this MIME type.
     * @deprecated
     */
    readonly enabledPlugin: Plugin;
    /**
     * Returns the MIME type's typical file extensions, in a comma-separated list.
     * @deprecated
     */
    readonly suffixes: string;
    /**
     * Returns the MIME type.
     * @deprecated
     */
    readonly type: string;
}

/** @deprecated */
declare var MimeType: {
    prototype: MimeType;
    new(): MimeType;
};

/**
 * The **`MimeTypeArray`** interface returns an array of MimeType instances, each of which contains information about a supported browser plugins. This object is returned by the deprecated Navigator.mimeTypes property.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MimeTypeArray)
 */
interface MimeTypeArray {
    /** @deprecated */
    readonly length: number;
    /** @deprecated */
    item(index: number): MimeType | null;
    /** @deprecated */
    namedItem(name: string): MimeType | null;
    [index: number]: MimeType;
}

/** @deprecated */
declare var MimeTypeArray: {
    prototype: MimeTypeArray;
    new(): MimeTypeArray;
};

/**
 * The **`MouseEvent`** interface represents events that occur due to the user interacting with a pointing device (such as a mouse). Common events using this interface include click, dblclick, mouseup, mousedown.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent)
 */
interface MouseEvent extends UIEvent {
    /**
     * The **`MouseEvent.altKey`** read-only property is a boolean value that indicates whether the alt key was pressed or not when a given mouse event occurs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/altKey)
     */
    readonly altKey: boolean;
    /**
     * The **`MouseEvent.button`** read-only property indicates which button was pressed or released on the mouse to trigger the event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/button)
     */
    readonly button: number;
    /**
     * The **`MouseEvent.buttons`** read-only property indicates which buttons are pressed on the mouse (or other input device) when a mouse event is triggered.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/buttons)
     */
    readonly buttons: number;
    /**
     * The **`clientX`** read-only property of the MouseEvent interface provides the horizontal coordinate within the application's viewport at which the event occurred (as opposed to the coordinate within the page).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/clientX)
     */
    readonly clientX: number;
    /**
     * The **`clientY`** read-only property of the MouseEvent interface provides the vertical coordinate within the application's viewport at which the event occurred (as opposed to the coordinate within the page).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/clientY)
     */
    readonly clientY: number;
    /**
     * The **`MouseEvent.ctrlKey`** read-only property is a boolean value that indicates whether the ctrl key was pressed or not when a given mouse event occurs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/ctrlKey)
     */
    readonly ctrlKey: boolean;
    /**
     * The **`MouseEvent.layerX`** read-only property returns the horizontal coordinate of the event relative to the current layer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/layerX)
     */
    readonly layerX: number;
    /**
     * The **`MouseEvent.layerY`** read-only property returns the vertical coordinate of the event relative to the current layer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/layerY)
     */
    readonly layerY: number;
    /**
     * The **`MouseEvent.metaKey`** read-only property is a boolean value that indicates whether the meta key was pressed or not when a given mouse event occurs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/metaKey)
     */
    readonly metaKey: boolean;
    /**
     * The **`movementX`** read-only property of the MouseEvent interface provides the difference in the X coordinate of the mouse (or pointer) between the given move event and the previous move event of the same type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/movementX)
     */
    readonly movementX: number;
    /**
     * The **`movementY`** read-only property of the MouseEvent interface provides the difference in the Y coordinate of the mouse (or pointer) between the given move event and the previous move event of the same type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/movementY)
     */
    readonly movementY: number;
    /**
     * The **`offsetX`** read-only property of the MouseEvent interface provides the offset in the X coordinate of the mouse pointer between that event and the padding edge of the target node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/offsetX)
     */
    readonly offsetX: number;
    /**
     * The **`offsetY`** read-only property of the MouseEvent interface provides the offset in the Y coordinate of the mouse pointer between that event and the padding edge of the target node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/offsetY)
     */
    readonly offsetY: number;
    /**
     * The **`pageX`** read-only property of the MouseEvent interface returns the X (horizontal) coordinate (in pixels) at which the mouse was clicked, relative to the left edge of the entire document. This includes any portion of the document not currently visible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/pageX)
     */
    readonly pageX: number;
    /**
     * The **`pageY`** read-only property of the MouseEvent interface returns the Y (vertical) coordinate (in pixels) at which the mouse was clicked, relative to the top edge of the entire document. This includes any portion of the document not currently visible.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/pageY)
     */
    readonly pageY: number;
    /**
     * The **`MouseEvent.relatedTarget`** read-only property is the secondary target for the mouse event, if there is one.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/relatedTarget)
     */
    readonly relatedTarget: EventTarget | null;
    /**
     * The **`screenX`** read-only property of the MouseEvent interface provides the horizontal coordinate (offset) of the mouse pointer in screen coordinates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/screenX)
     */
    readonly screenX: number;
    /**
     * The **`screenY`** read-only property of the MouseEvent interface provides the vertical coordinate (offset) of the mouse pointer in screen coordinates.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/screenY)
     */
    readonly screenY: number;
    /**
     * The **`MouseEvent.shiftKey`** read-only property is a boolean value that indicates whether the shift key was pressed or not when a given mouse event occurs.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/shiftKey)
     */
    readonly shiftKey: boolean;
    /**
     * The **`MouseEvent.x`** property is an alias for the MouseEvent.clientX property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/x)
     */
    readonly x: number;
    /**
     * The **`MouseEvent.y`** property is an alias for the MouseEvent.clientY property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/y)
     */
    readonly y: number;
    /**
     * The **`MouseEvent.getModifierState()`** method returns the current state of the specified modifier key: true if the modifier is active (i.e., the modifier key is pressed or locked), otherwise, false.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/getModifierState)
     */
    getModifierState(keyArg: string): boolean;
    /**
     * The **`MouseEvent.initMouseEvent()`** method initializes the value of a mouse event once it's been created (normally using the Document.createEvent() method).
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MouseEvent/initMouseEvent)
     */
    initMouseEvent(typeArg: string, canBubbleArg: boolean, cancelableArg: boolean, viewArg: Window, detailArg: number, screenXArg: number, screenYArg: number, clientXArg: number, clientYArg: number, ctrlKeyArg: boolean, altKeyArg: boolean, shiftKeyArg: boolean, metaKeyArg: boolean, buttonArg: number, relatedTargetArg: EventTarget | null): void;
}

declare var MouseEvent: {
    prototype: MouseEvent;
    new(type: string, eventInitDict?: MouseEventInit): MouseEvent;
};

/**
 * The **`MutationObserver`** interface provides the ability to watch for changes being made to the DOM tree. It is designed as a replacement for the older Mutation Events feature, which was part of the DOM3 Events specification.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationObserver)
 */
interface MutationObserver {
    /**
     * The MutationObserver method **`disconnect()`** tells the observer to stop watching for mutations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationObserver/disconnect)
     */
    disconnect(): void;
    /**
     * The MutationObserver method **`observe()`** configures the MutationObserver callback to begin receiving notifications of changes to the DOM that match the given options.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationObserver/observe)
     */
    observe(target: Node, options?: MutationObserverInit): void;
    /**
     * The MutationObserver method **`takeRecords()`** returns a list of all matching DOM changes that have been detected but not yet processed by the observer's callback function, leaving the mutation queue empty.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationObserver/takeRecords)
     */
    takeRecords(): MutationRecord[];
}

declare var MutationObserver: {
    prototype: MutationObserver;
    new(callback: MutationCallback): MutationObserver;
};

/**
 * The **`MutationRecord`** is a read-only interface that represents an individual DOM mutation observed by a MutationObserver. It is the object inside the array passed to the callback of a MutationObserver.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord)
 */
interface MutationRecord {
    /**
     * The MutationRecord read-only property **`addedNodes`** is a NodeList of nodes added to a target node by a mutation observed with a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/addedNodes)
     */
    readonly addedNodes: NodeList;
    /**
     * The MutationRecord read-only property **`attributeName`** contains the name of a changed attribute belonging to a node that is observed by a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/attributeName)
     */
    readonly attributeName: string | null;
    /**
     * The MutationRecord read-only property **`attributeNamespace`** is the namespace of the mutated attribute in the MutationRecord observed by a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/attributeNamespace)
     */
    readonly attributeNamespace: string | null;
    /**
     * The MutationRecord read-only property **`nextSibling`** is the next sibling of an added or removed child node of the target of a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/nextSibling)
     */
    readonly nextSibling: Node | null;
    /**
     * The MutationRecord read-only property **`oldValue`** contains the character data or attribute value of an observed node before it was changed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/oldValue)
     */
    readonly oldValue: string | null;
    /**
     * The MutationRecord read-only property **`previousSibling`** is the previous sibling of an added or removed child node of the target of a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/previousSibling)
     */
    readonly previousSibling: Node | null;
    /**
     * The MutationRecord read-only property **`removedNodes`** is a NodeList of nodes removed from a target node by a mutation observed with a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/removedNodes)
     */
    readonly removedNodes: NodeList;
    /**
     * The MutationRecord read-only property **`target`** is the target (i.e., the mutated/changed node) of a mutation observed with a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/target)
     */
    readonly target: Node;
    /**
     * The MutationRecord read-only property **`type`** is the type of the MutationRecord observed by a MutationObserver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/MutationRecord/type)
     */
    readonly type: MutationRecordType;
}

declare var MutationRecord: {
    prototype: MutationRecord;
    new(): MutationRecord;
};

/**
 * The **`NamedNodeMap`** interface represents a collection of Attr objects. Objects inside a NamedNodeMap are not in any particular order, unlike NodeList, although they may be accessed by an index as in an array.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap)
 */
interface NamedNodeMap {
    /**
     * The read-only **`length`** property of the NamedNodeMap interface is the number of objects stored in the map.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/length)
     */
    readonly length: number;
    /**
     * The **`getNamedItem()`** method of the NamedNodeMap interface returns the Attr corresponding to the given name, or null if there is no corresponding attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/getNamedItem)
     */
    getNamedItem(qualifiedName: string): Attr | null;
    /**
     * The **`getNamedItemNS()`** method of the NamedNodeMap interface returns the Attr corresponding to the given local name in the given namespace, or null if there is no corresponding attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/getNamedItemNS)
     */
    getNamedItemNS(namespace: string | null, localName: string): Attr | null;
    /**
     * The **`item()`** method of the NamedNodeMap interface returns the item in the map matching the index.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/item)
     */
    item(index: number): Attr | null;
    /**
     * The **`removeNamedItem()`** method of the NamedNodeMap interface removes the Attr corresponding to the given name from the map.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/removeNamedItem)
     */
    removeNamedItem(qualifiedName: string): Attr;
    /**
     * The **`removeNamedItemNS()`** method of the NamedNodeMap interface removes the Attr corresponding to the given namespace and local name from the map.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/removeNamedItemNS)
     */
    removeNamedItemNS(namespace: string | null, localName: string): Attr;
    /**
     * The **`setNamedItem()`** method of the NamedNodeMap interface puts the Attr identified by its name in the map. If there is already an Attr with the same name in the map, it is replaced.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/setNamedItem)
     */
    setNamedItem(attr: Attr): Attr | null;
    /**
     * The **`setNamedItemNS()`** method of the NamedNodeMap interface puts the Attr identified by its name in the map. If there was already an Attr with the same name in the map, it is replaced.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NamedNodeMap/setNamedItemNS)
     */
    setNamedItemNS(attr: Attr): Attr | null;
    [index: number]: Attr;
}

declare var NamedNodeMap: {
    prototype: NamedNodeMap;
    new(): NamedNodeMap;
};

/**
 * The **`NavigateEvent`** interface of the Navigation API is the event object for the navigate event, which fires when any type of navigation is initiated (this includes usage of History API features like History.go()). NavigateEvent provides access to information about that navigation, and allows developers to intercept and control the navigation handling.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent)
 */
interface NavigateEvent extends Event {
    /**
     * The **`canIntercept`** read-only property of the NavigateEvent interface returns true if the navigation can be intercepted and have its URL rewritten, or false otherwise
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/canIntercept)
     */
    readonly canIntercept: boolean;
    /**
     * The **`destination`** read-only property of the NavigateEvent interface returns a NavigationDestination object representing the destination being navigated to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/destination)
     */
    readonly destination: NavigationDestination;
    /**
     * The **`downloadRequest`** read-only property of the NavigateEvent interface returns the filename of the file requested for download, in the case of a download navigation (e.g., an <a> or <area> element with a download attribute), or null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/downloadRequest)
     */
    readonly downloadRequest: string | null;
    /**
     * The **`formData`** read-only property of the NavigateEvent interface returns the FormData object representing the submitted data in the case of a POST form submission, or null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/formData)
     */
    readonly formData: FormData | null;
    /**
     * The **`hasUAVisualTransition`** read-only property of the NavigateEvent interface returns true if the user agent performed a visual transition for this navigation before dispatching this event, or false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/hasUAVisualTransition)
     */
    readonly hasUAVisualTransition: boolean;
    /**
     * The **`hashChange`** read-only property of the NavigateEvent interface returns true if the navigation is a fragment navigation (i.e., to a fragment identifier in the same document), or false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/hashChange)
     */
    readonly hashChange: boolean;
    /**
     * The **`info`** read-only property of the NavigateEvent interface returns the info data value passed by the initiating navigation operation (e.g., Navigation.back(), or Navigation.navigate()), or undefined if no info data was passed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/info)
     */
    readonly info: any;
    /**
     * The **`navigationType`** read-only property of the NavigateEvent interface returns the type of the navigation — push, reload, replace, or traverse.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/navigationType)
     */
    readonly navigationType: NavigationType;
    /**
     * The **`signal`** read-only property of the NavigateEvent interface returns an AbortSignal, which will become aborted if the navigation is cancelled (e.g., by the user pressing the browser's "Stop" button, or another navigation starting and thus cancelling the ongoing one).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/signal)
     */
    readonly signal: AbortSignal;
    /**
     * The **`sourceElement`** read-only property of the NavigateEvent interface returns an Element object representing the initiating element, in cases where the navigation was initiated by an element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/sourceElement)
     */
    readonly sourceElement: Element | null;
    /**
     * The **`userInitiated`** read-only property of the NavigateEvent interface returns true if the navigation was initiated by the user (e.g., by clicking a link, submitting a form, or pressing the browser's "Back"/"Forward" buttons), or false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/userInitiated)
     */
    readonly userInitiated: boolean;
    /**
     * The **`intercept()`** method of the NavigateEvent interface intercepts this navigation, turning it into a same-document navigation to the destination URL.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/intercept)
     */
    intercept(options?: NavigationInterceptOptions): void;
    /**
     * The **`scroll()`** method of the NavigateEvent interface can be called to manually trigger the browser-driven scrolling behavior that occurs in response to the navigation, if you want it to happen before the navigation handling has completed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigateEvent/scroll)
     */
    scroll(): void;
}

declare var NavigateEvent: {
    prototype: NavigateEvent;
    new(type: string, eventInitDict: NavigateEventInit): NavigateEvent;
};

interface NavigationEventMap {
    "currententrychange": NavigationCurrentEntryChangeEvent;
    "navigate": NavigateEvent;
    "navigateerror": ErrorEvent;
    "navigatesuccess": Event;
}

/**
 * The **`Navigation`** interface of the Navigation API allows control over all navigation actions for the current window in one central place, including initiating navigations programmatically, examining navigation history entries, and managing navigations as they happen.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation)
 */
interface Navigation extends EventTarget {
    /**
     * The **`activation`** read-only property of the Navigation interface returns a NavigationActivation object containing information about the most recent cross-document navigation, which "activated" this Document. The property will stay constant during same-document navigations.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/activation)
     */
    readonly activation: NavigationActivation | null;
    /**
     * The **`canGoBack`** read-only property of the Navigation interface returns true if it is possible to navigate backwards in the navigation history (i.e., the currentEntry is not the first one in the history entry list), and false if it is not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/canGoBack)
     */
    readonly canGoBack: boolean;
    /**
     * The **`canGoForward`** read-only property of the Navigation interface returns true if it is possible to navigate forwards in the navigation history (i.e., the currentEntry is not the last one in the history entry list), and false if it is not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/canGoForward)
     */
    readonly canGoForward: boolean;
    /**
     * The **`currentEntry`** read-only property of the Navigation interface returns a NavigationHistoryEntry object representing the location the user is currently navigated to right now.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/currentEntry)
     */
    readonly currentEntry: NavigationHistoryEntry | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/currententrychange_event) */
    oncurrententrychange: ((this: Navigation, ev: NavigationCurrentEntryChangeEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/navigate_event) */
    onnavigate: ((this: Navigation, ev: NavigateEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/navigateerror_event) */
    onnavigateerror: ((this: Navigation, ev: ErrorEvent) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/navigatesuccess_event) */
    onnavigatesuccess: ((this: Navigation, ev: Event) => any) | null;
    /**
     * The **`transition`** read-only property of the Navigation interface returns a NavigationTransition object representing the status of an in-progress navigation, which can be used to track it.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/transition)
     */
    readonly transition: NavigationTransition | null;
    /**
     * The **`back()`** method of the Navigation interface navigates backwards by one entry in the navigation history.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/back)
     */
    back(options?: NavigationOptions): NavigationResult;
    /**
     * The **`entries()`** method of the Navigation interface returns an array of NavigationHistoryEntry objects representing all existing history entries.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/entries)
     */
    entries(): NavigationHistoryEntry[];
    /**
     * The **`forward()`** method of the Navigation interface navigates forwards by one entry in the navigation history.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/forward)
     */
    forward(options?: NavigationOptions): NavigationResult;
    /**
     * The **`navigate()`** method of the Navigation interface navigates to a specific URL, updating any provided state in the history entries list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/navigate)
     */
    navigate(url: string | URL, options?: NavigationNavigateOptions): NavigationResult;
    /**
     * The **`reload()`** method of the Navigation interface reloads the current URL, updating any provided state in the history entries list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/reload)
     */
    reload(options?: NavigationReloadOptions): NavigationResult;
    /**
     * The **`traverseTo()`** method of the Navigation interface navigates to the NavigationHistoryEntry identified by the given key.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/traverseTo)
     */
    traverseTo(key: string, options?: NavigationOptions): NavigationResult;
    /**
     * The **`updateCurrentEntry()`** method of the Navigation interface updates the state of the currentEntry; used in cases where the state change will be independent of a navigation or reload.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigation/updateCurrentEntry)
     */
    updateCurrentEntry(options: NavigationUpdateCurrentEntryOptions): void;
    addEventListener<K extends keyof NavigationEventMap>(type: K, listener: (this: Navigation, ev: NavigationEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof NavigationEventMap>(type: K, listener: (this: Navigation, ev: NavigationEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Navigation: {
    prototype: Navigation;
    new(): Navigation;
};

/**
 * The **`NavigationActivation`** interface of the Navigation API represents a recent cross-document navigation. It contains the navigation type and outgoing and inbound document history entries.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationActivation)
 */
interface NavigationActivation {
    /**
     * The **`entry`** read-only property of the NavigationActivation interface contains a NavigationHistoryEntry object representing the history entry for the inbound ("to") document in the navigation. This is equivalent to the Navigation.currentEntry property at the moment the inbound document was activated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationActivation/entry)
     */
    readonly entry: NavigationHistoryEntry;
    /**
     * The **`from`** read-only property of the NavigationActivation interface contains a NavigationHistoryEntry object representing the history entry for the outgoing ("from") document in the navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationActivation/from)
     */
    readonly from: NavigationHistoryEntry | null;
    /**
     * The **`navigationType`** read-only property of the NavigationActivation interface contains a string indicating the type of navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationActivation/navigationType)
     */
    readonly navigationType: NavigationType;
}

declare var NavigationActivation: {
    prototype: NavigationActivation;
    new(): NavigationActivation;
};

/**
 * The **`NavigationCurrentEntryChangeEvent`** interface of the Navigation API is the event object for the currententrychange event, which fires when the Navigation.currentEntry has changed.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationCurrentEntryChangeEvent)
 */
interface NavigationCurrentEntryChangeEvent extends Event {
    /**
     * The **`from`** read-only property of the NavigationCurrentEntryChangeEvent interface returns the NavigationHistoryEntry that was navigated from.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationCurrentEntryChangeEvent/from)
     */
    readonly from: NavigationHistoryEntry;
    /**
     * The **`navigationType`** read-only property of the NavigationCurrentEntryChangeEvent interface returns the type of the navigation that resulted in the change. The property may be null if the change occurs due to Navigation.updateCurrentEntry().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationCurrentEntryChangeEvent/navigationType)
     */
    readonly navigationType: NavigationType | null;
}

declare var NavigationCurrentEntryChangeEvent: {
    prototype: NavigationCurrentEntryChangeEvent;
    new(type: string, eventInitDict: NavigationCurrentEntryChangeEventInit): NavigationCurrentEntryChangeEvent;
};

/**
 * The **`NavigationDestination`** interface of the Navigation API represents the destination being navigated to in the current navigation.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination)
 */
interface NavigationDestination {
    /**
     * The **`id`** read-only property of the NavigationDestination interface returns the id value of the destination NavigationHistoryEntry if the NavigateEvent.navigationType is traverse, or an empty string otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination/id)
     */
    readonly id: string;
    /**
     * The **`index`** read-only property of the NavigationDestination interface returns the index value of the destination NavigationHistoryEntry if the NavigateEvent.navigationType is traverse, or -1 otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination/index)
     */
    readonly index: number;
    /**
     * The **`key`** read-only property of the NavigationDestination interface returns the key value of the destination NavigationHistoryEntry if the NavigateEvent.navigationType is traverse, or an empty string otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination/key)
     */
    readonly key: string;
    /**
     * The **`sameDocument`** read-only property of the NavigationDestination interface returns true if the navigation is to the same document as the current Document value, or false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination/sameDocument)
     */
    readonly sameDocument: boolean;
    /**
     * The **`url`** read-only property of the NavigationDestination interface returns the URL being navigated to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination/url)
     */
    readonly url: string;
    /**
     * The **`getState()`** method of the NavigationDestination interface returns a clone of the developer-supplied state associated with the destination NavigationHistoryEntry, or navigation operation (e.g., navigate()) as appropriate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationDestination/getState)
     */
    getState(): any;
}

declare var NavigationDestination: {
    prototype: NavigationDestination;
    new(): NavigationDestination;
};

interface NavigationHistoryEntryEventMap {
    "dispose": Event;
}

/**
 * The **`NavigationHistoryEntry`** interface of the Navigation API represents a single navigation history entry.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry)
 */
interface NavigationHistoryEntry extends EventTarget {
    /**
     * The **`id`** read-only property of the NavigationHistoryEntry interface returns the id of the history entry, or an empty string if current document is not fully active. This is a unique, UA-generated value that always represents a specific history entry, useful to correlate it with an external resource such as a storage cache.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/id)
     */
    readonly id: string;
    /**
     * The **`index`** read-only property of the NavigationHistoryEntry interface returns the index of the history entry in the history entries list (that is, the list returned by Navigation.entries()), or -1 if the entry does not appear in the list or if current document is not fully active.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/index)
     */
    readonly index: number;
    /**
     * The **`key`** read-only property of the NavigationHistoryEntry interface returns the key of the history entry, or an empty string if current document is not fully active. This is a unique, UA-generated value that represents the history entry's slot in the entries list. It is used to navigate that particular slot via Navigation.traverseTo(). The key will be reused by other entries that replace the entry in the list (that is, if the NavigateEvent.navigationType is replace).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/key)
     */
    readonly key: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/dispose_event) */
    ondispose: ((this: NavigationHistoryEntry, ev: Event) => any) | null;
    /**
     * The **`sameDocument`** read-only property of the NavigationHistoryEntry interface returns true if this history entry is for the same document as the current Document value and current document is fully active, or false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/sameDocument)
     */
    readonly sameDocument: boolean;
    /**
     * The **`url`** read-only property of the NavigationHistoryEntry interface returns the absolute URL of this history entry. If the entry corresponds to a different Document than the current one (like sameDocument property is false), and that Document was fetched with a Referrer-Policy header set to no-referrer or origin, the property returns null. If current document is not fully active, it returns an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/url)
     */
    readonly url: string | null;
    /**
     * The **`getState()`** method of the NavigationHistoryEntry interface returns a clone of the developer-supplied state associated with this history entry.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationHistoryEntry/getState)
     */
    getState(): any;
    addEventListener<K extends keyof NavigationHistoryEntryEventMap>(type: K, listener: (this: NavigationHistoryEntry, ev: NavigationHistoryEntryEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof NavigationHistoryEntryEventMap>(type: K, listener: (this: NavigationHistoryEntry, ev: NavigationHistoryEntryEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var NavigationHistoryEntry: {
    prototype: NavigationHistoryEntry;
    new(): NavigationHistoryEntry;
};

/**
 * The **`NavigationPrecommitController`** interface of the Navigation API is passed as an argument to a navigation precommit handler callback.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPrecommitController)
 */
interface NavigationPrecommitController {
    /**
     * The **`addHandler()`** method of the NavigationPrecommitController interface allows you to dynamically add a handler callback function in precommit code, which will then be run after the navigation has committed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPrecommitController/addHandler)
     */
    addHandler(handler: NavigationInterceptHandler): void;
    /**
     * The **`redirect()`** method of the NavigationPrecommitController interface redirects the browser to a specified URL and specifies history behavior and any desired state information.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPrecommitController/redirect)
     */
    redirect(url: string | URL, options?: NavigationNavigateOptions): void;
}

declare var NavigationPrecommitController: {
    prototype: NavigationPrecommitController;
    new(): NavigationPrecommitController;
};

/**
 * The **`NavigationPreloadManager`** interface of the Service Worker API provides methods for managing the preloading of resources in parallel with service worker bootup.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPreloadManager)
 */
interface NavigationPreloadManager {
    /**
     * The **`disable()`** method of the NavigationPreloadManager interface halts the automatic preloading of service-worker-managed resources previously started using enable() It returns a promise that resolves with undefined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPreloadManager/disable)
     */
    disable(): Promise<void>;
    /**
     * The **`enable()`** method of the NavigationPreloadManager interface is used to enable preloading of resources managed by the service worker. It returns a promise that resolves with undefined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPreloadManager/enable)
     */
    enable(): Promise<void>;
    /**
     * The **`getState()`** method of the NavigationPreloadManager interface returns a Promise that resolves to an object with properties that indicate whether preload is enabled and what value will be sent in the Service-Worker-Navigation-Preload HTTP header.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPreloadManager/getState)
     */
    getState(): Promise<NavigationPreloadState>;
    /**
     * The **`setHeaderValue()`** method of the NavigationPreloadManager interface sets the value of the Service-Worker-Navigation-Preload header that will be sent with requests resulting from a fetch() operation made during service worker navigation preloading. It returns an empty Promise that resolves with undefined.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationPreloadManager/setHeaderValue)
     */
    setHeaderValue(value: string): Promise<void>;
}

declare var NavigationPreloadManager: {
    prototype: NavigationPreloadManager;
    new(): NavigationPreloadManager;
};

/**
 * The **`NavigationTransition`** interface of the Navigation API represents an ongoing navigation, that is, a navigation that hasn't yet reached the navigatesuccess or navigateerror stage.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationTransition)
 */
interface NavigationTransition {
    readonly committed: Promise<void>;
    /**
     * The **`finished`** read-only property of the NavigationTransition interface returns a Promise that fulfills at the same time the navigatesuccess event fires, or rejects at the same time the navigateerror event fires.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationTransition/finished)
     */
    readonly finished: Promise<void>;
    /**
     * The **`from`** read-only property of the NavigationTransition interface returns the NavigationHistoryEntry that the transition is coming from.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationTransition/from)
     */
    readonly from: NavigationHistoryEntry;
    /**
     * The **`navigationType`** read-only property of the NavigationTransition interface returns the type of the ongoing navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigationTransition/navigationType)
     */
    readonly navigationType: NavigationType;
}

declare var NavigationTransition: {
    prototype: NavigationTransition;
    new(): NavigationTransition;
};

/**
 * The **`Navigator`** interface represents the state and the identity of the user agent. It allows scripts to query it and to register themselves to carry on some activities.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator)
 */
interface Navigator extends NavigatorAutomationInformation, NavigatorBadge, NavigatorConcurrentHardware, NavigatorContentUtils, NavigatorCookies, NavigatorGPU, NavigatorID, NavigatorLanguage, NavigatorLocks, NavigatorOnLine, NavigatorPlugins, NavigatorStorage {
    /**
     * The **`clipboard`** read-only property of the Navigator interface returns a Clipboard object used to read and write the clipboard's contents.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/clipboard)
     */
    readonly clipboard: Clipboard;
    /**
     * The **`credentials`** read-only property of the Navigator interface returns the CredentialsContainer object associated with the current document, which exposes methods to request credentials. The CredentialsContainer interface also notifies the user agent when an interesting event occurs, such as a successful sign-in or sign-out. This interface can be used for feature detection.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/credentials)
     */
    readonly credentials: CredentialsContainer;
    /** The **`Navigator.doNotTrack`** property returns the user's Do Not Track setting, which indicates whether the user is requesting websites and advertisers to not track them. */
    readonly doNotTrack: string | null;
    /**
     * The **`Navigator.geolocation`** read-only property returns a Geolocation object that gives Web content access to the location of the device. This allows a website or app to offer customized results based on the user's location.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/geolocation)
     */
    readonly geolocation: Geolocation;
    /**
     * The **`login`** read-only property of the Navigator interface provides access to the browser's NavigatorLogin object, which a federated identity provider (IdP) can use to set its login status when a user signs into or out of the IdP.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/login)
     */
    readonly login: NavigatorLogin;
    /**
     * The **`maxTouchPoints`** read-only property of the Navigator interface returns the maximum number of simultaneous touch contact points that are supported by the current device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/maxTouchPoints)
     */
    readonly maxTouchPoints: number;
    /**
     * The **`mediaCapabilities`** read-only property of the Navigator interface references a MediaCapabilities object that can expose information about the decoding and encoding capabilities for a given media format and output capabilities.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/mediaCapabilities)
     */
    readonly mediaCapabilities: MediaCapabilities;
    /**
     * The **`mediaDevices`** read-only property of the Navigator interface returns a MediaDevices object, which provides access to connected media input devices like cameras and microphones, as well as screen sharing.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/mediaDevices)
     */
    readonly mediaDevices: MediaDevices;
    /**
     * The **`mediaSession`** read-only property of the Navigator interface returns a MediaSession object that can be used to share with the browser metadata and other information about the current playback state of media being handled by a document.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/mediaSession)
     */
    readonly mediaSession: MediaSession;
    /**
     * The **`permissions`** read-only property of the Navigator interface returns a Permissions object that can be used to query and update permission status of APIs covered by the Permissions API.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/permissions)
     */
    readonly permissions: Permissions;
    /**
     * The **`serviceWorker`** read-only property of the Navigator interface returns the ServiceWorkerContainer object for the associated document, which provides access to registration, removal, upgrade, and communication with the ServiceWorker.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/serviceWorker)
     */
    readonly serviceWorker: ServiceWorkerContainer;
    /**
     * The read-only **`userActivation`** property of the Navigator interface returns a UserActivation object which contains information about the current window's user activation state.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/userActivation)
     */
    readonly userActivation: UserActivation;
    /**
     * The **`wakeLock`** read-only property of the Navigator interface returns a WakeLock interface that allows a document to acquire a screen wake lock. While a screen wake lock is active, the user agent will try to prevent the device from dimming the screen, turning it off completely, or showing a screensaver.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/wakeLock)
     */
    readonly wakeLock: WakeLock;
    /**
     * The **`canShare()`** method of the Navigator interface returns true if the equivalent call to navigator.share() would succeed.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/canShare)
     */
    canShare(data?: ShareData): boolean;
    /**
     * The **`Navigator.getGamepads()`** method returns an array of Gamepad objects, one for each gamepad connected to the device.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/getGamepads)
     */
    getGamepads(): (Gamepad | null)[];
    /**
     * The **`requestMIDIAccess()`** method of the Navigator interface returns a Promise representing a request for access to MIDI devices on a user's system. This method is part of the Web MIDI API, which provides a means for accessing, enumerating, and manipulating MIDI devices.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/requestMIDIAccess)
     */
    requestMIDIAccess(options?: MIDIOptions): Promise<MIDIAccess>;
    /**
     * The **`requestMediaKeySystemAccess()`** method of the Navigator interface returns a Promise which delivers a MediaKeySystemAccess object that can be used to access a particular media key system, which can in turn be used to create keys for decrypting a media stream.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/requestMediaKeySystemAccess)
     */
    requestMediaKeySystemAccess(keySystem: string, supportedConfigurations: MediaKeySystemConfiguration[]): Promise<MediaKeySystemAccess>;
    /**
     * The **`navigator.sendBeacon()`** method asynchronously sends an HTTP POST request containing a small amount of data to a web server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/sendBeacon)
     */
    sendBeacon(url: string | URL, data?: BodyInit | null): boolean;
    /**
     * The **`share()`** method of the Navigator interface invokes the native sharing mechanism of the device to share data such as text, URLs, or files. The available share targets depend on the device, but might include the clipboard, contacts and email applications, websites, Bluetooth, etc.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/share)
     */
    share(data?: ShareData): Promise<void>;
    /**
     * The **`vibrate()`** method of the Navigator interface pulses the vibration hardware on the device, if such hardware exists. If the device doesn't support vibration, this method has no effect. If a vibration pattern is already in progress when this method is called, the previous pattern is halted and the new one begins instead.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/vibrate)
     */
    vibrate(pattern: VibratePattern): boolean;
}

declare var Navigator: {
    prototype: Navigator;
    new(): Navigator;
};

interface NavigatorAutomationInformation {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/webdriver) */
    readonly webdriver: boolean;
}

/** Available only in secure contexts. */
interface NavigatorBadge {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/clearAppBadge) */
    clearAppBadge(): Promise<void>;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/setAppBadge) */
    setAppBadge(contents?: number): Promise<void>;
}

interface NavigatorConcurrentHardware {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/hardwareConcurrency) */
    readonly hardwareConcurrency: number;
}

interface NavigatorContentUtils {
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/registerProtocolHandler)
     */
    registerProtocolHandler(scheme: string, url: string | URL): void;
}

interface NavigatorCookies {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/cookieEnabled) */
    readonly cookieEnabled: boolean;
}

interface NavigatorGPU {
    /**
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/gpu)
     */
    readonly gpu: GPU;
}

interface NavigatorID {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/appCodeName) */
    readonly appCodeName: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/appName) */
    readonly appName: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/appVersion) */
    readonly appVersion: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/platform) */
    readonly platform: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/product) */
    readonly product: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/productSub) */
    readonly productSub: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/userAgent) */
    readonly userAgent: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/vendor) */
    readonly vendor: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/vendorSub) */
    readonly vendorSub: string;
}

interface NavigatorLanguage {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/language) */
    readonly language: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/languages) */
    readonly languages: ReadonlyArray<string>;
}

/** Available only in secure contexts. */
interface NavigatorLocks {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/locks) */
    readonly locks: LockManager;
}

/**
 * The **`NavigatorLogin`** interface of the Federated Credential Management (FedCM) API defines login functionality for federated identity providers (IdPs). Specifically, it enables a federated identity provider (IdP) to set its login status when a user signs into or out of the IdP.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigatorLogin)
 */
interface NavigatorLogin {
    /**
     * The **`setStatus()`** method of the NavigatorLogin interface sets the login status of a federated identity provider (IdP), when called from the IdP's origin. By this, we mean "whether any users are logged into the IdP on the current browser or not". This should be called by the IdP site following a user login or logout.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NavigatorLogin/setStatus)
     */
    setStatus(status: LoginStatus): Promise<void>;
}

declare var NavigatorLogin: {
    prototype: NavigatorLogin;
    new(): NavigatorLogin;
};

interface NavigatorOnLine {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/onLine) */
    readonly onLine: boolean;
}

interface NavigatorPlugins {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/mimeTypes) */
    readonly mimeTypes: MimeTypeArray;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/pdfViewerEnabled) */
    readonly pdfViewerEnabled: boolean;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/plugins) */
    readonly plugins: PluginArray;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/javaEnabled) */
    javaEnabled(): boolean;
}

/** Available only in secure contexts. */
interface NavigatorStorage {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Navigator/storage) */
    readonly storage: StorageManager;
}

/**
 * The DOM **`Node`** interface is an abstract base class upon which many other DOM API objects are based, thus letting those object types be used similarly and often interchangeably. As an abstract class, there is no such thing as a plain Node object. All objects that implement Node functionality are based on one of its subclasses. Most notable are Document, Element, and DocumentFragment.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node)
 */
interface Node extends EventTarget {
    /**
     * The read-only **`baseURI`** property of the Node interface returns the absolute base URL of the document containing the node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/baseURI)
     */
    readonly baseURI: string;
    /**
     * The read-only **`childNodes`** property of the Node interface returns a live NodeList of child nodes of the given element where the first child node is assigned index 0. Child nodes include elements, text and comments.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/childNodes)
     */
    readonly childNodes: NodeListOf<ChildNode>;
    /**
     * The read-only **`firstChild`** property of the Node interface returns the node's first child in the tree, or null if the node has no children.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/firstChild)
     */
    readonly firstChild: ChildNode | null;
    /**
     * The read-only **`isConnected`** property of the Node interface returns a boolean indicating whether the node is connected (directly or indirectly) to a Document object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/isConnected)
     */
    readonly isConnected: boolean;
    /**
     * The read-only **`lastChild`** property of the Node interface returns the last child of the node, or null if there are no child nodes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/lastChild)
     */
    readonly lastChild: ChildNode | null;
    /**
     * The read-only **`nextSibling`** property of the Node interface returns the node immediately following the specified one in their parent's childNodes, or returns null if the specified node is the last child in the parent element.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/nextSibling)
     */
    readonly nextSibling: ChildNode | null;
    /**
     * The read-only **`nodeName`** property of Node returns the name of the current node as a string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/nodeName)
     */
    readonly nodeName: string;
    /**
     * The read-only **`nodeType`** property of a Node interface is an integer that identifies what the node is. It distinguishes different kinds of nodes from each other, such as elements, text, and comments.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/nodeType)
     */
    readonly nodeType: number;
    /**
     * The **`nodeValue`** property of the Node interface returns or sets the value of the current node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/nodeValue)
     */
    nodeValue: string | null;
    /**
     * The read-only **`ownerDocument`** property of the Node interface returns the top-level document object of the node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/ownerDocument)
     */
    readonly ownerDocument: Document | null;
    /**
     * The read-only **`parentElement`** property of Node interface returns the DOM node's parent Element, or null if the node either has no parent, or its parent isn't a DOM Element. Node.parentNode on the other hand returns any kind of parent, regardless of its type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/parentElement)
     */
    readonly parentElement: HTMLElement | null;
    /**
     * The read-only **`parentNode`** property of the Node interface returns the parent of the specified node in the DOM tree.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/parentNode)
     */
    readonly parentNode: ParentNode | null;
    /**
     * The read-only **`previousSibling`** property of the Node interface returns the node immediately preceding the specified one in its parent's childNodes list, or null if the specified node is the first in that list.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/previousSibling)
     */
    readonly previousSibling: ChildNode | null;
    /**
     * The **`textContent`** property of the Node interface represents the text content of the node and its descendants.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/textContent)
     */
    textContent: string | null;
    /**
     * The **`appendChild()`** method of the Node interface adds a node to the end of the list of children of a specified parent node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/appendChild)
     */
    appendChild<T extends Node>(node: T): T;
    /**
     * The **`cloneNode()`** method of the Node interface returns a duplicate of the node on which this method was called. Its parameter controls if the subtree contained in the node is also cloned or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/cloneNode)
     */
    cloneNode(subtree?: boolean): Node;
    /**
     * The **`compareDocumentPosition()`** method of the Node interface reports the position of its argument node relative to the node on which it is called.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/compareDocumentPosition)
     */
    compareDocumentPosition(other: Node): number;
    /**
     * The **`contains()`** method of the Node interface returns a boolean value indicating whether a node is a descendant of a given node, that is the node itself, one of its direct children (childNodes), one of the children's direct children, and so on.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/contains)
     */
    contains(other: Node | null): boolean;
    /**
     * The **`getRootNode()`** method of the Node interface returns the context object's root, which optionally includes the shadow root if it is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/getRootNode)
     */
    getRootNode(options?: GetRootNodeOptions): Node;
    /**
     * The **`hasChildNodes()`** method of the Node interface returns a boolean value indicating whether the given Node has child nodes or not.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/hasChildNodes)
     */
    hasChildNodes(): boolean;
    /**
     * The **`insertBefore()`** method of the Node interface inserts a node before a reference node as a child of a specified parent node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/insertBefore)
     */
    insertBefore<T extends Node>(node: T, child: Node | null): T;
    /**
     * The **`isDefaultNamespace()`** method of the Node interface accepts a namespace URI as an argument. It returns a boolean value that is true if the namespace is the default namespace on the given node and false if not. The default namespace can be retrieved with Node.lookupNamespaceURI() by passing null as the argument.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/isDefaultNamespace)
     */
    isDefaultNamespace(namespace: string | null): boolean;
    /**
     * The **`isEqualNode()`** method of the Node interface tests whether two nodes are equal. Two nodes are equal when they have the same type, defining characteristics (for elements, this would be their ID, number of children, and so forth), its attributes match, and so on. The specific set of data points that must match varies depending on the types of the nodes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/isEqualNode)
     */
    isEqualNode(otherNode: Node | null): boolean;
    /**
     * The **`isSameNode()`** method of the Node interface is a legacy alias the for the === strict equality operator. That is, it tests whether two nodes are the same (in other words, whether they reference the same object).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/isSameNode)
     */
    isSameNode(otherNode: Node | null): boolean;
    /**
     * The **`lookupNamespaceURI()`** method of the Node interface takes a prefix as parameter and returns the namespace URI associated with it on the given node if found (and null if not). This method's existence allows Node objects to be passed as a namespace resolver to XPathEvaluator.createExpression() and XPathEvaluator.evaluate().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/lookupNamespaceURI)
     */
    lookupNamespaceURI(prefix: string | null): string | null;
    /**
     * The **`lookupPrefix()`** method of the Node interface returns a string containing the prefix for a given namespace URI, if present, and null if not. When multiple prefixes are possible, the first prefix is returned.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/lookupPrefix)
     */
    lookupPrefix(namespace: string | null): string | null;
    /**
     * The **`normalize()`** method of the Node interface puts the specified node and all of its sub-tree into a normalized form. In a normalized sub-tree, no text nodes in the sub-tree are empty and there are no adjacent text nodes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/normalize)
     */
    normalize(): void;
    /**
     * The **`removeChild()`** method of the Node interface removes a child node from the DOM and returns the removed node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/removeChild)
     */
    removeChild<T extends Node>(child: T): T;
    /**
     * The **`replaceChild()`** method of the Node interface replaces a child node within the given (parent) node.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Node/replaceChild)
     */
    replaceChild<T extends Node>(node: Node, child: T): T;
    /** node is an element. */
    readonly ELEMENT_NODE: 1;
    readonly ATTRIBUTE_NODE: 2;
    /** node is a Text node. */
    readonly TEXT_NODE: 3;
    /** node is a CDATASection node. */
    readonly CDATA_SECTION_NODE: 4;
    readonly ENTITY_REFERENCE_NODE: 5;
    readonly ENTITY_NODE: 6;
    /** node is a ProcessingInstruction node. */
    readonly PROCESSING_INSTRUCTION_NODE: 7;
    /** node is a Comment node. */
    readonly COMMENT_NODE: 8;
    /** node is a document. */
    readonly DOCUMENT_NODE: 9;
    /** node is a doctype. */
    readonly DOCUMENT_TYPE_NODE: 10;
    /** node is a DocumentFragment node. */
    readonly DOCUMENT_FRAGMENT_NODE: 11;
    readonly NOTATION_NODE: 12;
    /** Set when node and other are not in the same tree. */
    readonly DOCUMENT_POSITION_DISCONNECTED: 0x01;
    /** Set when other is preceding node. */
    readonly DOCUMENT_POSITION_PRECEDING: 0x02;
    /** Set when other is following node. */
    readonly DOCUMENT_POSITION_FOLLOWING: 0x04;
    /** Set when other is an ancestor of node. */
    readonly DOCUMENT_POSITION_CONTAINS: 0x08;
    /** Set when other is a descendant of node. */
    readonly DOCUMENT_POSITION_CONTAINED_BY: 0x10;
    readonly DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 0x20;
}

declare var Node: {
    prototype: Node;
    new(): Node;
    /** node is an element. */
    readonly ELEMENT_NODE: 1;
    readonly ATTRIBUTE_NODE: 2;
    /** node is a Text node. */
    readonly TEXT_NODE: 3;
    /** node is a CDATASection node. */
    readonly CDATA_SECTION_NODE: 4;
    readonly ENTITY_REFERENCE_NODE: 5;
    readonly ENTITY_NODE: 6;
    /** node is a ProcessingInstruction node. */
    readonly PROCESSING_INSTRUCTION_NODE: 7;
    /** node is a Comment node. */
    readonly COMMENT_NODE: 8;
    /** node is a document. */
    readonly DOCUMENT_NODE: 9;
    /** node is a doctype. */
    readonly DOCUMENT_TYPE_NODE: 10;
    /** node is a DocumentFragment node. */
    readonly DOCUMENT_FRAGMENT_NODE: 11;
    readonly NOTATION_NODE: 12;
    /** Set when node and other are not in the same tree. */
    readonly DOCUMENT_POSITION_DISCONNECTED: 0x01;
    /** Set when other is preceding node. */
    readonly DOCUMENT_POSITION_PRECEDING: 0x02;
    /** Set when other is following node. */
    readonly DOCUMENT_POSITION_FOLLOWING: 0x04;
    /** Set when other is an ancestor of node. */
    readonly DOCUMENT_POSITION_CONTAINS: 0x08;
    /** Set when other is a descendant of node. */
    readonly DOCUMENT_POSITION_CONTAINED_BY: 0x10;
    readonly DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 0x20;
};

/**
 * The **`NodeIterator`** interface represents an iterator to traverse nodes of a DOM subtree in document order.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator)
 */
interface NodeIterator {
    /**
     * The **`NodeIterator.filter`** read-only property returns a NodeFilter object, that is an object which implements an acceptNode(node) method, used to screen nodes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/filter)
     */
    readonly filter: NodeFilter | null;
    /**
     * The **`NodeIterator.pointerBeforeReferenceNode`** read-only property returns a boolean flag that indicates whether the NodeFilter is anchored before (if this value is true) or after (if this value is false) the anchor node indicated by the NodeIterator.referenceNode property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/pointerBeforeReferenceNode)
     */
    readonly pointerBeforeReferenceNode: boolean;
    /**
     * The **`NodeIterator.referenceNode`** read-only property returns the Node to which the iterator is anchored; as new nodes are inserted, the iterator remains anchored to the reference node as specified by this property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/referenceNode)
     */
    readonly referenceNode: Node;
    /**
     * The **`NodeIterator.root`** read-only property represents the Node that is the root of what the NodeIterator traverses.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/root)
     */
    readonly root: Node;
    /**
     * The **`NodeIterator.whatToShow`** read-only property represents an unsigned integer representing a bitmask signifying what types of nodes should be returned by the NodeIterator.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/whatToShow)
     */
    readonly whatToShow: number;
    /**
     * The **`NodeIterator.detach()`** method is a no-op, kept for backward compatibility only.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/detach)
     */
    detach(): void;
    /**
     * The **`NodeIterator.nextNode()`** method returns the next node in the set represented by the NodeIterator and advances the position of the iterator within the set. The first call to nextNode() returns the first node in the set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/nextNode)
     */
    nextNode(): Node | null;
    /**
     * The **`NodeIterator.previousNode()`** method returns the previous node in the set represented by the NodeIterator and moves the position of the iterator backwards within the set.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeIterator/previousNode)
     */
    previousNode(): Node | null;
}

declare var NodeIterator: {
    prototype: NodeIterator;
    new(): NodeIterator;
};

/**
 * **`NodeList`** objects are collections of nodes, usually returned by properties such as Node.childNodes and methods such as document.querySelectorAll().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeList)
 */
interface NodeList {
    /**
     * The **`NodeList.length`** property returns the number of items in a NodeList.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeList/length)
     */
    readonly length: number;
    /**
     * Returns a node from a NodeList by index. This method doesn't throw exceptions as long as you provide arguments. A value of null is returned if the index is out of range, and a TypeError is thrown if no argument is provided.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/NodeList/item)
     */
    item(index: number): Node | null;
    forEach(callbackfn: (value: Node, key: number, parent: NodeList) => void, thisArg?: any): void;
    [index: number]: Node;
}

declare var NodeList: {
    prototype: NodeList;
    new(): NodeList;
};

interface NodeListOf<TNode extends Node> extends NodeList {
    item(index: number): TNode;
    forEach(callbackfn: (value: TNode, key: number, parent: NodeListOf<TNode>) => void, thisArg?: any): void;
    [index: number]: TNode;
}

interface NonDocumentTypeChildNode {
    /**
     * Returns the first following sibling that is an element, and null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CharacterData/nextElementSibling)
     */
    readonly nextElementSibling: Element | null;
    /**
     * Returns the first preceding sibling that is an element, and null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/CharacterData/previousElementSibling)
     */
    readonly previousElementSibling: Element | null;
}

interface NonElementParentNode {
    /**
     * Returns the first element within node's descendants whose ID is elementId.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/getElementById)
     */
    getElementById(elementId: string): Element | null;
}

interface NotificationEventMap {
    "click": Event;
    "close": Event;
    "error": Event;
    "show": Event;
}

/**
 * The **`Notification`** interface of the Notifications API is used to configure and display desktop notifications to the user.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification)
 */
interface Notification extends EventTarget {
    /**
     * The **`body`** read-only property of the Notification interface indicates the body string of the notification, as specified in the body option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/body)
     */
    readonly body: string;
    /**
     * The **`data`** read-only property of the Notification interface returns a structured clone of the notification's data, as specified in the data option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/data)
     */
    readonly data: any;
    /**
     * The **`dir`** read-only property of the Notification interface indicates the text direction of the notification, as specified in the dir option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/dir)
     */
    readonly dir: NotificationDirection;
    /**
     * The **`icon`** read-only property of the Notification interface contains the URL of an icon to be displayed as part of the notification, as specified in the icon option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/icon)
     */
    readonly icon: string;
    /**
     * The **`lang`** read-only property of the Notification interface indicates the language used in the notification, as specified in the lang option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/lang)
     */
    readonly lang: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/click_event) */
    onclick: ((this: Notification, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/close_event) */
    onclose: ((this: Notification, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/error_event) */
    onerror: ((this: Notification, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/show_event) */
    onshow: ((this: Notification, ev: Event) => any) | null;
    /**
     * The **`requireInteraction`** read-only property of the Notification interface returns a boolean value indicating that a notification should remain active until the user clicks or dismisses it, rather than closing automatically.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/requireInteraction)
     */
    readonly requireInteraction: boolean;
    /**
     * The **`silent`** read-only property of the Notification interface specifies whether the notification should be silent, i.e., no sounds or vibrations should be issued regardless of the device settings. This is controlled via the silent option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/silent)
     */
    readonly silent: boolean | null;
    /**
     * The **`tag`** read-only property of the Notification interface signifies an identifying tag for the notification, as specified in the tag option of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/tag)
     */
    readonly tag: string;
    /**
     * The **`title`** read-only property of the Notification interface indicates the title of the notification, as specified in the title parameter of the Notification() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/title)
     */
    readonly title: string;
    /**
     * The **`close()`** method of the Notification interface is used to close/remove a previously displayed notification.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/close)
     */
    close(): void;
    addEventListener<K extends keyof NotificationEventMap>(type: K, listener: (this: Notification, ev: NotificationEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof NotificationEventMap>(type: K, listener: (this: Notification, ev: NotificationEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Notification: {
    prototype: Notification;
    new(title: string, options?: NotificationOptions): Notification;
    /**
     * The **`permission`** read-only static property of the Notification interface indicates the current permission granted by the user for the current origin to display web notifications.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/permission_static)
     */
    readonly permission: NotificationPermission;
    /**
     * The **`requestPermission()`** static method of the Notification interface requests permission from the user for the current origin to display notifications.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Notification/requestPermission_static)
     */
    requestPermission(deprecatedCallback?: NotificationPermissionCallback): Promise<NotificationPermission>;
};

/**
 * The **`OES_draw_buffers_indexed`** extension is part of the WebGL API and enables the use of different blend options when writing to multiple color buffers simultaneously.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed)
 */
interface OES_draw_buffers_indexed {
    /**
     * The **`blendEquationSeparateiOES()`** method of the OES_draw_buffers_indexed WebGL extension sets the RGB and alpha blend equations separately for a particular draw buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/blendEquationSeparateiOES)
     */
    blendEquationSeparateiOES(buf: GLuint, modeRGB: GLenum, modeAlpha: GLenum): void;
    /**
     * The **`blendEquationiOES()`** method of the OES_draw_buffers_indexed WebGL extension sets both the RGB blend and alpha blend equations for a particular draw buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/blendEquationiOES)
     */
    blendEquationiOES(buf: GLuint, mode: GLenum): void;
    /**
     * The **`blendFuncSeparateiOES()`** method of the OES_draw_buffers_indexed WebGL extension defines which function is used when blending pixels for RGB and alpha components separately for a particular draw buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/blendFuncSeparateiOES)
     */
    blendFuncSeparateiOES(buf: GLuint, srcRGB: GLenum, dstRGB: GLenum, srcAlpha: GLenum, dstAlpha: GLenum): void;
    /**
     * The **`blendFunciOES()`** method of the OES_draw_buffers_indexed WebGL extension defines which function is used when blending pixels for a particular draw buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/blendFunciOES)
     */
    blendFunciOES(buf: GLuint, src: GLenum, dst: GLenum): void;
    /**
     * The **`colorMaskiOES()`** method of the OES_draw_buffers_indexed WebGL extension sets which color components to enable or to disable when drawing or rendering for a particular draw buffer. It's the indexed version of WebGL 1's WebGLRenderingContext.colorMask() method.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/colorMaskiOES)
     */
    colorMaskiOES(buf: GLuint, r: GLboolean, g: GLboolean, b: GLboolean, a: GLboolean): void;
    /**
     * The **`disableiOES()`** method of the OES_draw_buffers_indexed WebGL extension enables blending for a particular draw buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/disableiOES)
     */
    disableiOES(target: GLenum, index: GLuint): void;
    /**
     * The **`enableiOES()`** method of the OES_draw_buffers_indexed WebGL extension enables blending for a particular draw buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_draw_buffers_indexed/enableiOES)
     */
    enableiOES(target: GLenum, index: GLuint): void;
}

/**
 * The **`OES_element_index_uint`** extension is part of the WebGL API and adds support for gl.UNSIGNED_INT types to WebGLRenderingContext.drawElements().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_element_index_uint)
 */
interface OES_element_index_uint {
}

/**
 * The **`OES_fbo_render_mipmap`** extension is part of the WebGL API and makes it possible to attach any level of a texture to a framebuffer object.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_fbo_render_mipmap)
 */
interface OES_fbo_render_mipmap {
}

/**
 * The **`OES_standard_derivatives`** extension is part of the WebGL API and adds the GLSL derivative functions dFdx, dFdy, and fwidth.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_standard_derivatives)
 */
interface OES_standard_derivatives {
    readonly FRAGMENT_SHADER_DERIVATIVE_HINT_OES: 0x8B8B;
}

/**
 * The **`OES_texture_float`** extension is part of the WebGL API and exposes floating-point pixel types for textures.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_texture_float)
 */
interface OES_texture_float {
}

/**
 * The **`OES_texture_float_linear`** extension is part of the WebGL API and allows linear filtering with floating-point pixel types for textures.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_texture_float_linear)
 */
interface OES_texture_float_linear {
}

/**
 * The **`OES_texture_half_float`** extension is part of the WebGL API and adds texture formats with 16- (aka half float) and 32-bit floating-point components.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_texture_half_float)
 */
interface OES_texture_half_float {
    readonly HALF_FLOAT_OES: 0x8D61;
}

/**
 * The **`OES_texture_half_float_linear`** extension is part of the WebGL API and allows linear filtering with half floating-point pixel types for textures.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_texture_half_float_linear)
 */
interface OES_texture_half_float_linear {
}

/**
 * The **`OES_vertex_array_object`** extension is part of the WebGL API and provides vertex array objects (VAOs) which encapsulate vertex array states. These objects keep pointers to vertex data and provide names for different sets of vertex data.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_vertex_array_object)
 */
interface OES_vertex_array_object {
    /**
     * The **`OES_vertex_array_object.bindVertexArrayOES()`** method of the WebGL API binds a passed WebGLVertexArrayObject object to the buffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_vertex_array_object/bindVertexArrayOES)
     */
    bindVertexArrayOES(arrayObject: WebGLVertexArrayObjectOES | null): void;
    /**
     * The **`OES_vertex_array_object.createVertexArrayOES()`** method of the WebGL API creates and initializes a WebGLVertexArrayObject object that represents a vertex array object (VAO) pointing to vertex array data and which provides names for different sets of vertex data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_vertex_array_object/createVertexArrayOES)
     */
    createVertexArrayOES(): WebGLVertexArrayObjectOES;
    /**
     * The **`OES_vertex_array_object.deleteVertexArrayOES()`** method of the WebGL API deletes a given WebGLVertexArrayObject object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_vertex_array_object/deleteVertexArrayOES)
     */
    deleteVertexArrayOES(arrayObject: WebGLVertexArrayObjectOES | null): void;
    /**
     * The **`OES_vertex_array_object.isVertexArrayOES()`** method of the WebGL API returns true if the passed object is a WebGLVertexArrayObject object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OES_vertex_array_object/isVertexArrayOES)
     */
    isVertexArrayOES(arrayObject: WebGLVertexArrayObjectOES | null): GLboolean;
    readonly VERTEX_ARRAY_BINDING_OES: 0x85B5;
}

/**
 * The **`OVR_multiview2`** extension is part of the WebGL API and adds support for rendering into multiple views simultaneously. This especially useful for virtual reality (VR) and WebXR.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OVR_multiview2)
 */
interface OVR_multiview2 {
    /**
     * The **`OVR_multiview2.framebufferTextureMultiviewOVR()`** method of the WebGL API attaches a multiview texture to a WebGLFramebuffer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OVR_multiview2/framebufferTextureMultiviewOVR)
     */
    framebufferTextureMultiviewOVR(target: GLenum, attachment: GLenum, texture: WebGLTexture | null, level: GLint, baseViewIndex: GLint, numViews: GLsizei): void;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_NUM_VIEWS_OVR: 0x9630;
    readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_BASE_VIEW_INDEX_OVR: 0x9632;
    readonly MAX_VIEWS_OVR: 0x9631;
    readonly FRAMEBUFFER_INCOMPLETE_VIEW_TARGETS_OVR: 0x9633;
}

/**
 * The Web Audio API **`OfflineAudioCompletionEvent`** interface represents events that occur when the processing of an OfflineAudioContext is terminated. The complete event uses this interface.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioCompletionEvent)
 */
interface OfflineAudioCompletionEvent extends Event {
    /**
     * The **`renderedBuffer`** read-only property of the OfflineAudioCompletionEvent interface is an AudioBuffer containing the result of processing an OfflineAudioContext.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioCompletionEvent/renderedBuffer)
     */
    readonly renderedBuffer: AudioBuffer;
}

declare var OfflineAudioCompletionEvent: {
    prototype: OfflineAudioCompletionEvent;
    new(type: string, eventInitDict: OfflineAudioCompletionEventInit): OfflineAudioCompletionEvent;
};

interface OfflineAudioContextEventMap extends BaseAudioContextEventMap {
    "complete": OfflineAudioCompletionEvent;
}

/**
 * The **`OfflineAudioContext`** interface is an AudioContext interface representing an audio-processing graph built from linked together AudioNodes. In contrast with a standard AudioContext, an OfflineAudioContext doesn't render the audio to the device hardware; instead, it generates it, as fast as it can, and outputs the result to an AudioBuffer.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioContext)
 */
interface OfflineAudioContext extends BaseAudioContext {
    /**
     * The **`length`** property of the OfflineAudioContext interface returns an integer representing the size of the buffer in sample-frames.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioContext/length)
     */
    readonly length: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioContext/complete_event) */
    oncomplete: ((this: OfflineAudioContext, ev: OfflineAudioCompletionEvent) => any) | null;
    /**
     * The **`resume()`** method of the OfflineAudioContext interface resumes the progression of time in an audio context that has been suspended. The promise resolves immediately because the OfflineAudioContext does not require the audio hardware.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioContext/resume)
     */
    resume(): Promise<void>;
    /**
     * The **`startRendering()`** method of the OfflineAudioContext Interface starts rendering the audio graph, taking into account the current connections and the current scheduled changes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioContext/startRendering)
     */
    startRendering(): Promise<AudioBuffer>;
    /**
     * The **`suspend()`** method of the OfflineAudioContext interface schedules a suspension of the time progression in the audio context at the specified time and returns a promise. This is generally useful at the time of manipulating the audio graph synchronously on OfflineAudioContext.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OfflineAudioContext/suspend)
     */
    suspend(suspendTime: number): Promise<void>;
    addEventListener<K extends keyof OfflineAudioContextEventMap>(type: K, listener: (this: OfflineAudioContext, ev: OfflineAudioContextEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof OfflineAudioContextEventMap>(type: K, listener: (this: OfflineAudioContext, ev: OfflineAudioContextEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var OfflineAudioContext: {
    prototype: OfflineAudioContext;
    new(contextOptions: OfflineAudioContextOptions): OfflineAudioContext;
    new(numberOfChannels: number, length: number, sampleRate: number): OfflineAudioContext;
};

interface OffscreenCanvasEventMap {
    "contextlost": Event;
    "contextrestored": Event;
}

/**
 * When using the <canvas> element or the Canvas API, rendering, animation, and user interaction usually happen on the main execution thread of a web application. The computation relating to canvas animations and rendering can have a significant impact on application performance.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas)
 */
interface OffscreenCanvas extends EventTarget {
    /**
     * The **`height`** property returns and sets the height of an OffscreenCanvas object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/height)
     */
    height: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/contextlost_event) */
    oncontextlost: ((this: OffscreenCanvas, ev: Event) => any) | null;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/contextrestored_event) */
    oncontextrestored: ((this: OffscreenCanvas, ev: Event) => any) | null;
    /**
     * The **`width`** property returns and sets the width of an OffscreenCanvas object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/width)
     */
    width: number;
    /**
     * The **`OffscreenCanvas.convertToBlob()`** method creates a Blob object representing the image contained in the canvas.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/convertToBlob)
     */
    convertToBlob(options?: ImageEncodeOptions): Promise<Blob>;
    /**
     * The **`OffscreenCanvas.getContext()`** method returns a drawing context for an offscreen canvas, or null if the context identifier is not supported, or the offscreen canvas has already been set to a different context mode.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/getContext)
     */
    getContext(contextId: "2d", options?: any): OffscreenCanvasRenderingContext2D | null;
    getContext(contextId: "bitmaprenderer", options?: any): ImageBitmapRenderingContext | null;
    getContext(contextId: "webgl", options?: any): WebGLRenderingContext | null;
    getContext(contextId: "webgl2", options?: any): WebGL2RenderingContext | null;
    getContext(contextId: OffscreenRenderingContextId, options?: any): OffscreenRenderingContext | null;
    /**
     * The **`OffscreenCanvas.transferToImageBitmap()`** method creates an ImageBitmap object from the most recently rendered image of the OffscreenCanvas. The OffscreenCanvas allocates a new image for its subsequent rendering.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvas/transferToImageBitmap)
     */
    transferToImageBitmap(): ImageBitmap;
    addEventListener<K extends keyof OffscreenCanvasEventMap>(type: K, listener: (this: OffscreenCanvas, ev: OffscreenCanvasEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof OffscreenCanvasEventMap>(type: K, listener: (this: OffscreenCanvas, ev: OffscreenCanvasEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var OffscreenCanvas: {
    prototype: OffscreenCanvas;
    new(width: number, height: number): OffscreenCanvas;
};

/**
 * The **`OffscreenCanvasRenderingContext2D`** interface is a CanvasRenderingContext2D rendering context for drawing to the bitmap of an OffscreenCanvas object. It is similar to the CanvasRenderingContext2D object, with the following differences:
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OffscreenCanvasRenderingContext2D)
 */
interface OffscreenCanvasRenderingContext2D extends CanvasCompositing, CanvasDrawImage, CanvasDrawPath, CanvasFillStrokeStyles, CanvasFilters, CanvasImageData, CanvasImageSmoothing, CanvasPath, CanvasPathDrawingStyles, CanvasRect, CanvasShadowStyles, CanvasState, CanvasText, CanvasTextDrawingStyles, CanvasTransform {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/CanvasRenderingContext2D/canvas) */
    readonly canvas: OffscreenCanvas;
}

declare var OffscreenCanvasRenderingContext2D: {
    prototype: OffscreenCanvasRenderingContext2D;
    new(): OffscreenCanvasRenderingContext2D;
};

/**
 * The **`OscillatorNode`** interface represents a periodic waveform, such as a sine wave. It is an AudioScheduledSourceNode audio-processing module that causes a specified frequency of a given wave to be created—in effect, a constant tone.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OscillatorNode)
 */
interface OscillatorNode extends AudioScheduledSourceNode {
    /**
     * The **`detune`** property of the OscillatorNode interface is an a-rate AudioParam representing detuning of oscillation in cents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OscillatorNode/detune)
     */
    readonly detune: AudioParam;
    /**
     * The **`frequency`** property of the OscillatorNode interface is an a-rate AudioParam representing the frequency of oscillation in hertz.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OscillatorNode/frequency)
     */
    readonly frequency: AudioParam;
    /**
     * The **`type`** property of the OscillatorNode interface specifies what shape of waveform the oscillator will output. There are several common waveforms available, as well as an option to specify a custom waveform shape. The shape of the waveform will affect the tone that is produced.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OscillatorNode/type)
     */
    type: OscillatorType;
    /**
     * The **`setPeriodicWave()`** method of the OscillatorNode interface is used to point to a PeriodicWave defining a periodic waveform that can be used to shape the oscillator's output, when type is custom.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OscillatorNode/setPeriodicWave)
     */
    setPeriodicWave(periodicWave: PeriodicWave): void;
    addEventListener<K extends keyof AudioScheduledSourceNodeEventMap>(type: K, listener: (this: OscillatorNode, ev: AudioScheduledSourceNodeEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof AudioScheduledSourceNodeEventMap>(type: K, listener: (this: OscillatorNode, ev: AudioScheduledSourceNodeEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var OscillatorNode: {
    prototype: OscillatorNode;
    new(context: BaseAudioContext, options?: OscillatorOptions): OscillatorNode;
};

/**
 * The **`OverconstrainedError`** interface of the Media Capture and Streams API indicates that the set of desired capabilities for the current MediaStreamTrack cannot currently be met. When this event is thrown on a MediaStreamTrack, it is muted until either the current constraints can be established or until satisfiable constraints are applied.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OverconstrainedError)
 */
interface OverconstrainedError extends DOMException {
    /**
     * The **`constraint`** read-only property of the OverconstrainedError interface returns the constraint that was supplied in the constructor, meaning the constraint that was not satisfied.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/OverconstrainedError/constraint)
     */
    readonly constraint: string;
}

declare var OverconstrainedError: {
    prototype: OverconstrainedError;
    new(constraint: string, message?: string): OverconstrainedError;
};

/**
 * The **`PageRevealEvent`** event object is made available inside handler functions for the pagereveal event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageRevealEvent)
 */
interface PageRevealEvent extends Event {
    /**
     * The **`viewTransition`** read-only property of the PageRevealEvent interface contains a ViewTransition object representing the active view transition for the cross-document navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageRevealEvent/viewTransition)
     */
    readonly viewTransition: ViewTransition | null;
}

declare var PageRevealEvent: {
    prototype: PageRevealEvent;
    new(type: string, eventInitDict?: PageRevealEventInit): PageRevealEvent;
};

/**
 * The **`PageSwapEvent`** event object is made available inside handler functions for the pageswap event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageSwapEvent)
 */
interface PageSwapEvent extends Event {
    /**
     * The **`activation`** read-only property of the PageSwapEvent interface contains a NavigationActivation object containing the navigation type and current and destination document history entries for a same-origin navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageSwapEvent/activation)
     */
    readonly activation: NavigationActivation | null;
    /**
     * The **`viewTransition`** read-only property of the PageRevealEvent interface contains a ViewTransition object representing the active view transition for the cross-document navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageSwapEvent/viewTransition)
     */
    readonly viewTransition: ViewTransition | null;
}

declare var PageSwapEvent: {
    prototype: PageSwapEvent;
    new(type: string, eventInitDict?: PageSwapEventInit): PageSwapEvent;
};

/**
 * The **`PageTransitionEvent`** event object is available inside handler functions for the pageshow and pagehide events, fired when a document is being loaded or unloaded.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageTransitionEvent)
 */
interface PageTransitionEvent extends Event {
    /**
     * The **`persisted`** read-only property indicates if a webpage is loading from a cache.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PageTransitionEvent/persisted)
     */
    readonly persisted: boolean;
}

declare var PageTransitionEvent: {
    prototype: PageTransitionEvent;
    new(type: string, eventInitDict?: PageTransitionEventInit): PageTransitionEvent;
};

interface PaintTimingMixin {
    readonly paintTime: DOMHighResTimeStamp;
    readonly presentationTime: DOMHighResTimeStamp | null;
}

/**
 * The **`PannerNode`** interface defines an audio-processing object that represents the location, direction, and behavior of an audio source signal in a simulated physical space. This AudioNode uses right-hand Cartesian coordinates to describe the source's position as a vector and its orientation as a 3D directional cone.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode)
 */
interface PannerNode extends AudioNode {
    /**
     * The **`coneInnerAngle`** property of the PannerNode interface is a double value describing the angle, in degrees, of a cone inside of which there will be no volume reduction.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/coneInnerAngle)
     */
    coneInnerAngle: number;
    /**
     * The **`coneOuterAngle`** property of the PannerNode interface is a double value describing the angle, in degrees, of a cone outside of which the volume will be reduced by a constant value, defined by the coneOuterGain property.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/coneOuterAngle)
     */
    coneOuterAngle: number;
    /**
     * The **`coneOuterGain`** property of the PannerNode interface is a double value, describing the amount of volume reduction outside the cone, defined by the coneOuterAngle attribute.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/coneOuterGain)
     */
    coneOuterGain: number;
    /**
     * The **`distanceModel`** property of the PannerNode interface is an enumerated value determining which algorithm to use to reduce the volume of the audio source as it moves away from the listener.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/distanceModel)
     */
    distanceModel: DistanceModelType;
    /**
     * The **`maxDistance`** property of the PannerNode interface is a double value representing the maximum distance between the audio source and the listener, after which the volume is not reduced any further. This value is used only by the linear distance model.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/maxDistance)
     */
    maxDistance: number;
    /**
     * The **`orientationX`** property of the PannerNode interface indicates the X (horizontal) component of the direction in which the audio source is facing, in a 3D Cartesian coordinate space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/orientationX)
     */
    readonly orientationX: AudioParam;
    /**
     * The **`orientationY`** property of the PannerNode interface indicates the Y (vertical) component of the direction the audio source is facing, in 3D Cartesian coordinate space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/orientationY)
     */
    readonly orientationY: AudioParam;
    /**
     * The **`orientationZ`** property of the PannerNode interface indicates the Z (depth) component of the direction the audio source is facing, in 3D Cartesian coordinate space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/orientationZ)
     */
    readonly orientationZ: AudioParam;
    /**
     * The **`panningModel`** property of the PannerNode interface is an enumerated value determining which spatialization algorithm to use to position the audio in 3D space.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/panningModel)
     */
    panningModel: PanningModelType;
    /**
     * The **`positionX`** property of the PannerNode interface specifies the X coordinate of the audio source's position in 3D Cartesian coordinates, corresponding to the horizontal axis (left-right).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/positionX)
     */
    readonly positionX: AudioParam;
    /**
     * The **`positionY`** property of the PannerNode interface specifies the Y coordinate of the audio source's position in 3D Cartesian coordinates, corresponding to the vertical axis (top-bottom). The complete vector is defined by the position of the audio source, given as (positionX, positionY, positionZ), and the orientation of the audio source (that is, the direction in which it's facing), given as (orientationX, orientationY, orientationZ).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/positionY)
     */
    readonly positionY: AudioParam;
    /**
     * The **`positionZ`** property of the PannerNode interface specifies the Z coordinate of the audio source's position in 3D Cartesian coordinates, corresponding to the depth axis (behind-in front of the listener). The complete vector is defined by the position of the audio source, given as (positionX, positionY, positionZ), and the orientation of the audio source (that is, the direction in which it's facing), given as (orientationX, orientationY, orientationZ).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/positionZ)
     */
    readonly positionZ: AudioParam;
    /**
     * The **`refDistance`** property of the PannerNode interface is a double value representing the reference distance for reducing volume as the audio source moves further from the listener – i.e., the distance at which the volume reduction starts taking effect. This value is used by all distance models.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/refDistance)
     */
    refDistance: number;
    /**
     * The **`rolloffFactor`** property of the PannerNode interface is a double value describing how quickly the volume is reduced as the source moves away from the listener. This value is used by all distance models. The rolloffFactor property's default value is 1.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/rolloffFactor)
     */
    rolloffFactor: number;
    /**
     * The **`setOrientation()`** method of the PannerNode Interface defines the direction the audio source is playing in.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/setOrientation)
     */
    setOrientation(x: number, y: number, z: number): void;
    /**
     * The **`setPosition()`** method of the PannerNode Interface defines the position of the audio source relative to the listener (represented by an AudioListener object stored in the BaseAudioContext.listener attribute.) The three parameters x, y and z are unitless and describe the source's position in 3D space using the right-hand Cartesian coordinate system.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PannerNode/setPosition)
     */
    setPosition(x: number, y: number, z: number): void;
}

declare var PannerNode: {
    prototype: PannerNode;
    new(context: BaseAudioContext, options?: PannerOptions): PannerNode;
};

interface ParentNode extends Node {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/childElementCount) */
    readonly childElementCount: number;
    /**
     * Returns the child elements.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/children)
     */
    readonly children: HTMLCollection;
    /**
     * Returns the first child that is an element, and null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/firstElementChild)
     */
    readonly firstElementChild: Element | null;
    /**
     * Returns the last child that is an element, and null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/lastElementChild)
     */
    readonly lastElementChild: Element | null;
    /**
     * Inserts nodes after the last child of node, while replacing strings in nodes with equivalent Text nodes.
     *
     * Throws a "HierarchyRequestError" DOMException if the constraints of the node tree are violated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/append)
     */
    append(...nodes: (Node | string)[]): void;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/moveBefore) */
    moveBefore(node: Node, child: Node | null): void;
    /**
     * Inserts nodes before the first child of node, while replacing strings in nodes with equivalent Text nodes.
     *
     * Throws a "HierarchyRequestError" DOMException if the constraints of the node tree are violated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/prepend)
     */
    prepend(...nodes: (Node | string)[]): void;
    /**
     * Returns the first element that is a descendant of node that matches selectors.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/querySelector)
     */
    querySelector<K extends keyof HTMLElementTagNameMap>(selectors: K): HTMLElementTagNameMap[K] | null;
    querySelector<K extends keyof SVGElementTagNameMap>(selectors: K): SVGElementTagNameMap[K] | null;
    querySelector<K extends keyof MathMLElementTagNameMap>(selectors: K): MathMLElementTagNameMap[K] | null;
    /** @deprecated */
    querySelector<K extends keyof HTMLElementDeprecatedTagNameMap>(selectors: K): HTMLElementDeprecatedTagNameMap[K] | null;
    querySelector<E extends Element = Element>(selectors: string): E | null;
    /**
     * Returns all element descendants of node that match selectors.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/querySelectorAll)
     */
    querySelectorAll<K extends keyof HTMLElementTagNameMap>(selectors: K): NodeListOf<HTMLElementTagNameMap[K]>;
    querySelectorAll<K extends keyof SVGElementTagNameMap>(selectors: K): NodeListOf<SVGElementTagNameMap[K]>;
    querySelectorAll<K extends keyof MathMLElementTagNameMap>(selectors: K): NodeListOf<MathMLElementTagNameMap[K]>;
    /** @deprecated */
    querySelectorAll<K extends keyof HTMLElementDeprecatedTagNameMap>(selectors: K): NodeListOf<HTMLElementDeprecatedTagNameMap[K]>;
    querySelectorAll<E extends Element = Element>(selectors: string): NodeListOf<E>;
    /**
     * Replace all children of node with nodes, while replacing strings in nodes with equivalent Text nodes.
     *
     * Throws a "HierarchyRequestError" DOMException if the constraints of the node tree are violated.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Document/replaceChildren)
     */
    replaceChildren(...nodes: (Node | string)[]): void;
}

/**
 * The **`Path2D`** interface of the Canvas 2D API is used to declare a path that can then be used on a CanvasRenderingContext2D object. The path methods of the CanvasRenderingContext2D interface are also present on this interface, which gives you the convenience of being able to retain and replay your path whenever desired.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Path2D)
 */
interface Path2D extends CanvasPath {
    /**
     * The **`Path2D.addPath()`** method of the Canvas 2D API adds one Path2D object to another Path2D object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Path2D/addPath)
     */
    addPath(path: Path2D, transform?: DOMMatrix2DInit): void;
}

declare var Path2D: {
    prototype: Path2D;
    new(path?: Path2D | string): Path2D;
};

/**
 * The **`ContactAddress`** interface of the Contact Picker API represents a physical address. Instances of this interface are retrieved from the address property of the objects returned by ContactsManager.getProperties().
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress)
 */
interface PaymentAddress {
    /**
     * The **`addressLine`** read-only property of the ContactAddress interface is an array of strings, each specifying a line of the address that is not covered by one of the other properties of ContactAddress. The array may include the street name, the house number, apartment number, the rural delivery route, descriptive instructions, or the post office box.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/addressLine)
     */
    readonly addressLine: ReadonlyArray<string>;
    /**
     * The **`city`** read-only property of the ContactAddress interface returns a string containing the city or town portion of the address.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/city)
     */
    readonly city: string;
    /**
     * The **`country`** read-only property of the ContactAddress interface is a string identifying the address's country using the ISO 3166-1 alpha-2 standard. The string is always in its canonical upper-case form.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/country)
     */
    readonly country: string;
    /**
     * The read-only **`dependentLocality`** property of the ContactAddress interface is a string containing a locality or sublocality designation within a city, such as a neighborhood, borough, district, or, in the United Kingdom, a dependent locality. Also known as a post town.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/dependentLocality)
     */
    readonly dependentLocality: string;
    /**
     * The **`organization`** read-only property of the ContactAddress interface returns a string containing the name of the organization, firm, company, or institution at the address.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/organization)
     */
    readonly organization: string;
    /**
     * The read-only **`phone`** property of the ContactAddress interface returns a string containing the telephone number of the recipient or contact person at the address.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/phone)
     */
    readonly phone: string;
    /**
     * The **`postalCode`** read-only property of the ContactAddress interface returns a string containing a code used by a jurisdiction for mail routing, for example, the ZIP Code in the United States or the Postal Index Number (PIN code) in India.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/postalCode)
     */
    readonly postalCode: string;
    /**
     * The read-only **`recipient`** property of the ContactAddress interface returns a string containing the name of the recipient, purchaser, or contact person at the address.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/recipient)
     */
    readonly recipient: string;
    /**
     * The read-only **`region`** property of the ContactAddress interface returns a string containing the top-level administrative subdivision of the country in which the address is located. This may be a state, province, oblast, or prefecture.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/region)
     */
    readonly region: string;
    /**
     * The **`sortingCode`** read-only property of the ContactAddress interface returns a string containing a postal sorting code such as is used in France.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/sortingCode)
     */
    readonly sortingCode: string;
    /**
     * The **`toJSON()`** method of the ContactAddress interface is a standard serializer that returns a JSON representation of the ContactAddress object's properties.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ContactAddress/toJSON)
     */
    toJSON(): any;
}

declare var PaymentAddress: {
    prototype: PaymentAddress;
    new(): PaymentAddress;
};

/**
 * The **`PaymentMethodChangeEvent`** interface of the Payment Request API describes the paymentmethodchange event which is fired by some payment handlers when the user switches payment instruments (e.g., a user selects a "store" card to make a purchase while using Apple Pay).
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentMethodChangeEvent)
 */
interface PaymentMethodChangeEvent extends PaymentRequestUpdateEvent {
    /**
     * The read-only **`methodDetails`** property of the PaymentMethodChangeEvent interface is an object containing any data the payment handler may provide to describe the change the user has made to their payment method. The value is null if no details are available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentMethodChangeEvent/methodDetails)
     */
    readonly methodDetails: any;
    /**
     * The read-only **`methodName`** property of the PaymentMethodChangeEvent interface is a string which uniquely identifies the payment handler currently selected by the user. The payment handler may be a payment technology, such as Apple Pay or Android Pay, and each payment handler may support multiple payment methods; changes to the payment method within the payment handler are described by the PaymentMethodChangeEvent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentMethodChangeEvent/methodName)
     */
    readonly methodName: string;
}

declare var PaymentMethodChangeEvent: {
    prototype: PaymentMethodChangeEvent;
    new(type: string, eventInitDict?: PaymentMethodChangeEventInit): PaymentMethodChangeEvent;
};

interface PaymentRequestEventMap {
    "paymentmethodchange": PaymentMethodChangeEvent;
    "shippingaddresschange": PaymentRequestUpdateEvent;
    "shippingoptionchange": PaymentRequestUpdateEvent;
}

/**
 * The Payment Request API's **`PaymentRequest`** interface is the primary access point into the API, and lets web content and apps accept payments from the end user on behalf of the operator of the site or the publisher of the app.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest)
 */
interface PaymentRequest extends EventTarget {
    /**
     * The **`id`** read-only attribute of the PaymentRequest interface returns a unique identifier for a particular PaymentRequest instance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/id)
     */
    readonly id: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/paymentmethodchange_event) */
    onpaymentmethodchange: ((this: PaymentRequest, ev: PaymentMethodChangeEvent) => any) | null;
    /**
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/shippingaddresschange_event)
     */
    onshippingaddresschange: ((this: PaymentRequest, ev: PaymentRequestUpdateEvent) => any) | null;
    /**
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/shippingoptionchange_event)
     */
    onshippingoptionchange: ((this: PaymentRequest, ev: PaymentRequestUpdateEvent) => any) | null;
    /**
     * The **`shippingAddress`** read-only property of the PaymentRequest interface returns the shipping address provided by the user. It is null by default.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/shippingAddress)
     */
    readonly shippingAddress: PaymentAddress | null;
    /**
     * The **`shippingOption`** read-only attribute of the PaymentRequest interface returns either the id of a selected shipping option, null (if no shipping option was set to be selected) or a shipping option selected by the user. It is initially null by when no "selected" shipping options are provided.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/shippingOption)
     */
    readonly shippingOption: string | null;
    /**
     * The **`shippingType`** read-only property of the PaymentRequest interface returns one of "shipping", "delivery", "pickup", or null if one was not provided by the constructor.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/shippingType)
     */
    readonly shippingType: PaymentShippingType | null;
    /**
     * The **`PaymentRequest.abort()`** method of the PaymentRequest interface causes the user agent to end the payment request and to remove any user interface that might be shown.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/abort)
     */
    abort(): Promise<void>;
    /**
     * The PaymentRequest method **`canMakePayment()`** determines whether or not the request is configured in a way that is compatible with at least one payment method supported by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/canMakePayment)
     */
    canMakePayment(): Promise<boolean>;
    /**
     * The PaymentRequest interface's **`show()`** method instructs the user agent to begin the process of showing and handling the user interface for the payment request to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequest/show)
     */
    show(detailsPromise?: PaymentDetailsUpdate | PromiseLike<PaymentDetailsUpdate>): Promise<PaymentResponse>;
    addEventListener<K extends keyof PaymentRequestEventMap>(type: K, listener: (this: PaymentRequest, ev: PaymentRequestEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof PaymentRequestEventMap>(type: K, listener: (this: PaymentRequest, ev: PaymentRequestEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var PaymentRequest: {
    prototype: PaymentRequest;
    new(methodData: PaymentMethodData[], details: PaymentDetailsInit, options?: PaymentOptions): PaymentRequest;
};

/**
 * The **`PaymentRequestUpdateEvent`** interface is used for events sent to a PaymentRequest instance when changes are made to shipping-related information for a pending PaymentRequest. Those events are:
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequestUpdateEvent)
 */
interface PaymentRequestUpdateEvent extends Event {
    /**
     * The **`updateWith()`** method of the PaymentRequestUpdateEvent interface updates the details of an existing PaymentRequest.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentRequestUpdateEvent/updateWith)
     */
    updateWith(detailsPromise: PaymentDetailsUpdate | PromiseLike<PaymentDetailsUpdate>): void;
}

declare var PaymentRequestUpdateEvent: {
    prototype: PaymentRequestUpdateEvent;
    new(type: string, eventInitDict?: PaymentRequestUpdateEventInit): PaymentRequestUpdateEvent;
};

interface PaymentResponseEventMap {
    "payerdetailchange": PaymentRequestUpdateEvent;
}

/**
 * The **`PaymentResponse`** interface of the Payment Request API is returned after a user selects a payment method and approves a payment request.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse)
 */
interface PaymentResponse extends EventTarget {
    /**
     * The **`details`** read-only property of the PaymentResponse interface returns a JSON-serializable object that provides a payment method specific message used by the merchant to process the transaction and determine a successful funds transfer.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/details)
     */
    readonly details: any;
    /**
     * The **`methodName`** read-only property of the PaymentResponse interface returns a string uniquely identifying the payment handler selected by the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/methodName)
     */
    readonly methodName: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/payerdetailchange_event) */
    onpayerdetailchange: ((this: PaymentResponse, ev: PaymentRequestUpdateEvent) => any) | null;
    /**
     * The **`payerEmail`** read-only property of the PaymentResponse interface returns the email address supplied by the user. This option is only present when the requestPayerEmail option is set to true in the options object passed to the PaymentRequest constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/payerEmail)
     */
    readonly payerEmail: string | null;
    /**
     * The **`payerName`** read-only property of the PaymentResponse interface returns the name supplied by the user. This option is only present when the requestPayerName option is set to true in the options parameter of the PaymentRequest() constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/payerName)
     */
    readonly payerName: string | null;
    /**
     * The **`payerPhone`** read-only property of the PaymentResponse interface returns the phone number supplied by the user. This option is only present when the requestPayerPhone option is set to true in the options object passed to the PaymentRequest constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/payerPhone)
     */
    readonly payerPhone: string | null;
    /**
     * The **`requestId`** read-only property of the PaymentResponse interface returns the free-form identifier supplied by the PaymentResponse() constructor by details.id.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/requestId)
     */
    readonly requestId: string;
    /**
     * The **`shippingAddress`** read-only property of the PaymentRequest interface returns a PaymentAddress object containing the shipping address provided by the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/shippingAddress)
     */
    readonly shippingAddress: PaymentAddress | null;
    /**
     * The **`shippingOption`** read-only property of the PaymentRequest interface returns the ID attribute of the shipping option selected by the user. This option is only present when the requestShipping option is set to true in the options object passed to the PaymentRequest constructor.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/shippingOption)
     */
    readonly shippingOption: string | null;
    /**
     * The PaymentRequest method **`complete()`** of the Payment Request API notifies the user agent that the user interaction is over, and causes any remaining user interface to be closed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/complete)
     */
    complete(result?: PaymentComplete): Promise<void>;
    /**
     * The PaymentResponse interface's **`retry()`** method makes it possible to ask the user to retry a payment after an error occurs during processing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/retry)
     */
    retry(errorFields?: PaymentValidationErrors): Promise<void>;
    /**
     * The **`toJSON()`** method of the PaymentResponse interface is a serializer; it returns a JSON representation of the PaymentResponse object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PaymentResponse/toJSON)
     */
    toJSON(): any;
    addEventListener<K extends keyof PaymentResponseEventMap>(type: K, listener: (this: PaymentResponse, ev: PaymentResponseEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof PaymentResponseEventMap>(type: K, listener: (this: PaymentResponse, ev: PaymentResponseEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var PaymentResponse: {
    prototype: PaymentResponse;
    new(): PaymentResponse;
};

interface PerformanceEventMap {
    "resourcetimingbufferfull": Event;
}

/**
 * The **`Performance`** interface provides access to performance-related information for the current page.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance)
 */
interface Performance extends EventTarget {
    /**
     * The read-only **`performance.eventCounts`** property is an EventCounts map containing the number of events which have been dispatched per event type since the page was loaded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/eventCounts)
     */
    readonly eventCounts: EventCounts;
    /**
     * The read-only **`performance.interactionCount`** property represents the number of real-user interactions that have occurred on the page since it was loaded.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/interactionCount)
     */
    readonly interactionCount: number;
    /**
     * The legacy **`Performance.navigation`** read-only property returns a PerformanceNavigation object representing the type of navigation that occurs in the given browsing context, such as the number of redirections needed to fetch the resource.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/navigation)
     */
    readonly navigation: PerformanceNavigation;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/resourcetimingbufferfull_event) */
    onresourcetimingbufferfull: ((this: Performance, ev: Event) => any) | null;
    /**
     * The **`timeOrigin`** read-only property of the Performance interface returns the high resolution timestamp that is used as the baseline for performance-related timestamps.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/timeOrigin)
     */
    readonly timeOrigin: DOMHighResTimeStamp;
    /**
     * The legacy **`Performance.timing`** read-only property returns a PerformanceTiming object containing latency-related performance information.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/timing)
     */
    readonly timing: PerformanceTiming;
    /**
     * The **`clearMarks()`** method removes all or specific PerformanceMark objects from the browser's performance timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/clearMarks)
     */
    clearMarks(markName?: string): void;
    /**
     * The **`clearMeasures()`** method removes all or specific PerformanceMeasure objects from the browser's performance timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/clearMeasures)
     */
    clearMeasures(measureName?: string): void;
    /**
     * The **`clearResourceTimings()`** method removes all performance entries with an entryType of "resource" from the browser's performance timeline and sets the size of the performance resource data buffer to zero.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/clearResourceTimings)
     */
    clearResourceTimings(): void;
    /**
     * The **`getEntries()`** method returns an array of all PerformanceEntry objects currently present in the performance timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/getEntries)
     */
    getEntries(): PerformanceEntryList;
    /**
     * The **`getEntriesByName()`** method returns an array of PerformanceEntry objects currently present in the performance timeline with the given name and type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/getEntriesByName)
     */
    getEntriesByName(name: string, type?: string): PerformanceEntryList;
    /**
     * The **`getEntriesByType()`** method returns an array of PerformanceEntry objects currently present in the performance timeline for a given type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/getEntriesByType)
     */
    getEntriesByType(type: string): PerformanceEntryList;
    /**
     * The **`mark()`** method creates a named PerformanceMark object representing a high resolution timestamp marker in the browser's performance timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/mark)
     */
    mark(markName: string, markOptions?: PerformanceMarkOptions): PerformanceMark;
    /**
     * The **`measure()`** method creates a named PerformanceMeasure object representing a time measurement between two marks in the browser's performance timeline.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/measure)
     */
    measure(measureName: string, startOrMeasureOptions?: string | PerformanceMeasureOptions, endMark?: string): PerformanceMeasure;
    /**
     * The **`performance.now()`** method returns a high resolution timestamp in milliseconds. It represents the time elapsed since Performance.timeOrigin (the time when navigation has started in window contexts, or the time when the worker is run in Worker and ServiceWorker contexts).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/now)
     */
    now(): DOMHighResTimeStamp;
    /**
     * The **`setResourceTimingBufferSize()`** method sets the desired size of the browser's resource timing buffer which stores the "resource" performance entries.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/setResourceTimingBufferSize)
     */
    setResourceTimingBufferSize(maxSize: number): void;
    /**
     * The **`toJSON()`** method of the Performance interface is a serializer; it returns a JSON representation of the Performance object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Performance/toJSON)
     */
    toJSON(): any;
    addEventListener<K extends keyof PerformanceEventMap>(type: K, listener: (this: Performance, ev: PerformanceEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof PerformanceEventMap>(type: K, listener: (this: Performance, ev: PerformanceEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var Performance: {
    prototype: Performance;
    new(): Performance;
};

/**
 * The **`PerformanceEntry`** object encapsulates a single performance metric that is part of the browser's performance timeline.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEntry)
 */
interface PerformanceEntry {
    /**
     * The read-only **`duration`** property returns a timestamp that is the duration of the performance entry. The meaning of this property depends on the value of this entry's entryType.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEntry/duration)
     */
    readonly duration: DOMHighResTimeStamp;
    /**
     * The read-only **`entryType`** property returns a string representing the type of performance metric that this entry represents.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEntry/entryType)
     */
    readonly entryType: string;
    /**
     * The read-only **`name`** property of the PerformanceEntry interface is a string representing the name for a performance entry. It acts as an identifier, but it does not have to be unique. The value depends on the subclass.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEntry/name)
     */
    readonly name: string;
    /**
     * The read-only **`startTime`** property returns the first timestamp recorded for this PerformanceEntry. The meaning of this property depends on the value of this entry's entryType.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEntry/startTime)
     */
    readonly startTime: DOMHighResTimeStamp;
    /**
     * The **`toJSON()`** method is a serializer; it returns a JSON representation of the PerformanceEntry object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEntry/toJSON)
     */
    toJSON(): any;
}

declare var PerformanceEntry: {
    prototype: PerformanceEntry;
    new(): PerformanceEntry;
};

/**
 * The **`PerformanceEventTiming`** interface of the Event Timing API provides insights into the latency of certain event types triggered by user interaction.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming)
 */
interface PerformanceEventTiming extends PerformanceEntry {
    /**
     * The read-only **`cancelable`** property returns the associated event's cancelable property, indicating whether the event can be canceled.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming/cancelable)
     */
    readonly cancelable: boolean;
    /**
     * The read-only **`interactionId`** property of the PerformanceEventTiming interface returns an ID that uniquely identifies a user interaction which triggered a series of associated events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming/interactionId)
     */
    readonly interactionId: number;
    /**
     * The read-only **`processingEnd`** property returns the time the last event handler finished executing.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming/processingEnd)
     */
    readonly processingEnd: DOMHighResTimeStamp;
    /**
     * The read-only **`processingStart`** property returns the time at which event dispatch started. This is when event handlers are about to be executed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming/processingStart)
     */
    readonly processingStart: DOMHighResTimeStamp;
    /**
     * The read-only **`target`** property returns the associated event's last target which is the node onto which the event was last dispatched.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming/target)
     */
    readonly target: Node | null;
    /**
     * The **`toJSON()`** method of the PerformanceEventTiming interface is a serializer; it returns a JSON representation of the PerformanceEventTiming object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceEventTiming/toJSON)
     */
    toJSON(): any;
}

declare var PerformanceEventTiming: {
    prototype: PerformanceEventTiming;
    new(): PerformanceEventTiming;
};

/**
 * **`PerformanceMark`** is an interface for PerformanceEntry objects with an entryType of "mark".
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceMark)
 */
interface PerformanceMark extends PerformanceEntry {
    /**
     * The read-only **`detail`** property returns arbitrary metadata that was included in the mark upon construction (either when using performance.mark() or the PerformanceMark() constructor).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceMark/detail)
     */
    readonly detail: any;
}

declare var PerformanceMark: {
    prototype: PerformanceMark;
    new(markName: string, markOptions?: PerformanceMarkOptions): PerformanceMark;
};

/**
 * **`PerformanceMeasure`** is an abstract interface for PerformanceEntry objects with an entryType of "measure". Entries of this type are created by calling performance.measure() to add a named DOMHighResTimeStamp (the measure) between two marks to the browser's performance timeline.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceMeasure)
 */
interface PerformanceMeasure extends PerformanceEntry {
    /**
     * The read-only **`detail`** property returns arbitrary metadata that was included in the mark upon construction (when using performance.measure().
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceMeasure/detail)
     */
    readonly detail: any;
}

declare var PerformanceMeasure: {
    prototype: PerformanceMeasure;
    new(): PerformanceMeasure;
};

/**
 * The legacy **`PerformanceNavigation`** interface represents information about how the navigation to the current document was done.
 * @deprecated This interface is deprecated in the Navigation Timing Level 2 specification. Please use the PerformanceNavigationTiming interface instead.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigation)
 */
interface PerformanceNavigation {
    /**
     * The legacy **`PerformanceNavigation.redirectCount`** read-only property returns an unsigned short representing the number of REDIRECTs done before reaching the page.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigation/redirectCount)
     */
    readonly redirectCount: number;
    /**
     * The legacy **`PerformanceNavigation.type`** read-only property returns an unsigned short containing a constant describing how the navigation to this page was done.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigation/type)
     */
    readonly type: number;
    /**
     * The **`toJSON()`** method of the PerformanceNavigation interface is a serializer; it returns a JSON representation of the PerformanceNavigation object.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigation/toJSON)
     */
    toJSON(): any;
    readonly TYPE_NAVIGATE: 0;
    readonly TYPE_RELOAD: 1;
    readonly TYPE_BACK_FORWARD: 2;
    readonly TYPE_RESERVED: 255;
}

/** @deprecated */
declare var PerformanceNavigation: {
    prototype: PerformanceNavigation;
    new(): PerformanceNavigation;
    readonly TYPE_NAVIGATE: 0;
    readonly TYPE_RELOAD: 1;
    readonly TYPE_BACK_FORWARD: 2;
    readonly TYPE_RESERVED: 255;
};

/**
 * The **`PerformanceNavigationTiming`** interface provides methods and properties to store and retrieve metrics regarding the browser's document navigation events. For example, this interface can be used to determine how much time it takes to load or unload a document.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming)
 */
interface PerformanceNavigationTiming extends PerformanceResourceTiming {
    /**
     * The **`domComplete`** read-only property returns a DOMHighResTimeStamp representing the time immediately before the user agent sets the document's readyState to "complete".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/domComplete)
     */
    readonly domComplete: DOMHighResTimeStamp;
    /**
     * The **`domContentLoadedEventEnd`** read-only property returns a DOMHighResTimeStamp representing the time immediately after the current document's DOMContentLoaded event handler completes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/domContentLoadedEventEnd)
     */
    readonly domContentLoadedEventEnd: DOMHighResTimeStamp;
    /**
     * The **`domContentLoadedEventStart`** read-only property returns a DOMHighResTimeStamp representing the time immediately before the current document's DOMContentLoaded event handler starts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/domContentLoadedEventStart)
     */
    readonly domContentLoadedEventStart: DOMHighResTimeStamp;
    /**
     * The **`domInteractive`** read-only property returns a DOMHighResTimeStamp representing the time immediately before the user agent sets the document's readyState to "interactive".
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/domInteractive)
     */
    readonly domInteractive: DOMHighResTimeStamp;
    /**
     * The **`loadEventEnd`** read-only property returns a DOMHighResTimeStamp representing the time immediately after the current document's load event handler completes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/loadEventEnd)
     */
    readonly loadEventEnd: DOMHighResTimeStamp;
    /**
     * The **`loadEventStart`** read-only property returns a DOMHighResTimeStamp representing the time immediately before the current document's load event handler starts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/loadEventStart)
     */
    readonly loadEventStart: DOMHighResTimeStamp;
    /**
     * The **`redirectCount`** read-only property returns a number representing the number of redirects since the last non-redirect navigation in the current browsing context.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/redirectCount)
     */
    readonly redirectCount: number;
    /**
     * The **`type`** read-only property returns the type of navigation.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/type)
     */
    readonly type: NavigationTimingType;
    /**
     * The **`unloadEventEnd`** read-only property returns a DOMHighResTimeStamp representing the time immediately after the previous document's unload event handler completes.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/unloadEventEnd)
     */
    readonly unloadEventEnd: DOMHighResTimeStamp;
    /**
     * The **`unloadEventStart`** read-only property returns a DOMHighResTimeStamp representing the time immediately before the previous document's unload event handler starts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/unloadEventStart)
     */
    readonly unloadEventStart: DOMHighResTimeStamp;
    /**
     * The **`toJSON()`** method of the PerformanceNavigationTiming interface is a serializer; it returns a JSON representation of the PerformanceNavigationTiming object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceNavigationTiming/toJSON)
     */
    toJSON(): any;
}

declare var PerformanceNavigationTiming: {
    prototype: PerformanceNavigationTiming;
    new(): PerformanceNavigationTiming;
};

/**
 * The **`PerformanceObserver`** interface is used to observe performance measurement events and be notified of new performance entries as they are recorded in the browser's performance timeline.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserver)
 */
interface PerformanceObserver {
    /**
     * The **`disconnect()`** method of the PerformanceObserver interface is used to stop the performance observer from receiving any performance entry events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserver/disconnect)
     */
    disconnect(): void;
    /**
     * The **`observe()`** method of the PerformanceObserver interface is used to specify the set of performance entry types to observe.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserver/observe)
     */
    observe(options?: PerformanceObserverInit): void;
    /**
     * The **`takeRecords()`** method of the PerformanceObserver interface returns the current list of PerformanceEntry objects stored in the performance observer, emptying it out.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserver/takeRecords)
     */
    takeRecords(): PerformanceEntryList;
}

declare var PerformanceObserver: {
    prototype: PerformanceObserver;
    new(callback: PerformanceObserverCallback): PerformanceObserver;
    /**
     * The static **`supportedEntryTypes`** read-only property of the PerformanceObserver interface returns an array of the entryType values supported by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserver/supportedEntryTypes_static)
     */
    readonly supportedEntryTypes: ReadonlyArray<string>;
};

/**
 * The **`PerformanceObserverEntryList`** interface is a list of performance events that were explicitly observed via the observe() method.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserverEntryList)
 */
interface PerformanceObserverEntryList {
    /**
     * The **`getEntries()`** method of the PerformanceObserverEntryList interface returns a list of explicitly observed performance entry objects. The list's members are determined by the set of entry types specified in the call to the observe() method. The list is available in the observer's callback function (as the first parameter in the callback).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserverEntryList/getEntries)
     */
    getEntries(): PerformanceEntryList;
    /**
     * The **`getEntriesByName()`** method of the PerformanceObserverEntryList interface returns a list of explicitly observed PerformanceEntry objects for a given name and entryType. The list's members are determined by the set of entry types specified in the call to the observe() method. The list is available in the observer's callback function (as the first parameter in the callback).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserverEntryList/getEntriesByName)
     */
    getEntriesByName(name: string, type?: string): PerformanceEntryList;
    /**
     * The **`getEntriesByType()`** method of the PerformanceObserverEntryList returns a list of explicitly observed performance entry objects for a given performance entry type. The list's members are determined by the set of entry types specified in the call to the observe() method. The list is available in the observer's callback function (as the first parameter in the callback).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceObserverEntryList/getEntriesByType)
     */
    getEntriesByType(type: string): PerformanceEntryList;
}

declare var PerformanceObserverEntryList: {
    prototype: PerformanceObserverEntryList;
    new(): PerformanceObserverEntryList;
};

/**
 * The **`PerformancePaintTiming`** interface provides timing information about "paint" (also called "render") operations during web page construction. "Paint" refers to conversion of the render tree to on-screen pixels.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformancePaintTiming)
 */
interface PerformancePaintTiming extends PerformanceEntry, PaintTimingMixin {
    /**
     * The **`toJSON()`** method of the PerformancePaintTiming interface is a serializer; it returns a JSON representation of the PerformancePaintTiming object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformancePaintTiming/toJSON)
     */
    toJSON(): any;
}

declare var PerformancePaintTiming: {
    prototype: PerformancePaintTiming;
    new(): PerformancePaintTiming;
};

/**
 * The **`PerformanceResourceTiming`** interface enables retrieval and analysis of detailed network timing data regarding the loading of an application's resources. An application can use the timing metrics to determine, for example, the length of time it takes to fetch a specific resource, such as an XMLHttpRequest, <SVG>, image, or script.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming)
 */
interface PerformanceResourceTiming extends PerformanceEntry {
    /**
     * The **`connectEnd`** read-only property returns the timestamp immediately after the browser finishes establishing the connection to the server to retrieve the resource. The timestamp value includes the time interval to establish the transport connection, as well as other time intervals such as TLS handshake and SOCKS authentication.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/connectEnd)
     */
    readonly connectEnd: DOMHighResTimeStamp;
    /**
     * The **`connectStart`** read-only property returns the timestamp immediately before the user agent starts establishing the connection to the server to retrieve the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/connectStart)
     */
    readonly connectStart: DOMHighResTimeStamp;
    /**
     * The **`decodedBodySize`** read-only property returns the size (in octets) received from the fetch (HTTP or cache) of the message body after removing any applied content encoding (like gzip or Brotli). If the resource is retrieved from an application cache or local resources, it returns the size of the payload after removing any applied content encoding.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/decodedBodySize)
     */
    readonly decodedBodySize: number;
    /**
     * The **`domainLookupEnd`** read-only property returns the timestamp immediately after the browser finishes the domain-name lookup for the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/domainLookupEnd)
     */
    readonly domainLookupEnd: DOMHighResTimeStamp;
    /**
     * The **`domainLookupStart`** read-only property returns the timestamp immediately before the browser starts the domain name lookup for the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/domainLookupStart)
     */
    readonly domainLookupStart: DOMHighResTimeStamp;
    /**
     * The **`encodedBodySize`** read-only property represents the size (in octets) received from the fetch (HTTP or cache) of the payload body before removing any applied content encodings (like gzip or Brotli). If the resource is retrieved from an application cache or a local resource, it must return the size of the payload body before removing any applied content encoding.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/encodedBodySize)
     */
    readonly encodedBodySize: number;
    /**
     * The **`fetchStart`** read-only property represents a timestamp immediately before the browser starts to fetch the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/fetchStart)
     */
    readonly fetchStart: DOMHighResTimeStamp;
    /**
     * The **`initiatorType`** read-only property is a string representing web platform feature that initiated the resource load.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/initiatorType)
     */
    readonly initiatorType: string;
    /**
     * The **`nextHopProtocol`** read-only property is a string representing the network protocol used to fetch the resource, as identified by the ALPN Protocol ID (RFC7301).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/nextHopProtocol)
     */
    readonly nextHopProtocol: string;
    /**
     * The **`redirectEnd`** read-only property returns a timestamp immediately after receiving the last byte of the response of the last redirect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/redirectEnd)
     */
    readonly redirectEnd: DOMHighResTimeStamp;
    /**
     * The **`redirectStart`** read-only property returns a timestamp representing the start time of the fetch which that initiates the redirect.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/redirectStart)
     */
    readonly redirectStart: DOMHighResTimeStamp;
    /**
     * The **`requestStart`** read-only property returns a timestamp of the time immediately before the browser starts requesting the resource from the server, cache, or local resource. If the transport connection fails and the browser retries the request, the value returned will be the start of the retry request.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/requestStart)
     */
    readonly requestStart: DOMHighResTimeStamp;
    /**
     * The **`responseEnd`** read-only property returns a timestamp immediately after the browser receives the last byte of the resource or immediately before the transport connection is closed, whichever comes first.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/responseEnd)
     */
    readonly responseEnd: DOMHighResTimeStamp;
    /**
     * The **`responseStart`** read-only property returns a timestamp immediately after the browser receives the first byte of the response from the server, cache, or local resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/responseStart)
     */
    readonly responseStart: DOMHighResTimeStamp;
    /**
     * The **`responseStatus`** read-only property represents the HTTP response status code returned when fetching the resource.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/responseStatus)
     */
    readonly responseStatus: number;
    /**
     * The **`secureConnectionStart`** read-only property returns a timestamp immediately before the browser starts the handshake process to secure the current connection. If a secure connection is not used, the property returns zero.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/secureConnectionStart)
     */
    readonly secureConnectionStart: DOMHighResTimeStamp;
    /**
     * The **`serverTiming`** read-only property returns an array of PerformanceServerTiming entries containing server timing metrics.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/serverTiming)
     */
    readonly serverTiming: ReadonlyArray<PerformanceServerTiming>;
    /**
     * The **`transferSize`** read-only property represents the size (in octets) of the fetched resource. The size includes the response header fields plus the response payload body (as defined by RFC7230).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/transferSize)
     */
    readonly transferSize: number;
    /**
     * The **`workerStart`** read-only property of the PerformanceResourceTiming interface returns a DOMHighResTimeStamp immediately before dispatching the FetchEvent if a Service Worker thread is already running, or immediately before starting the Service Worker thread if it is not already running. If the resource is not intercepted by a Service Worker the property will always return 0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/workerStart)
     */
    readonly workerStart: DOMHighResTimeStamp;
    /**
     * The **`toJSON()`** method of the PerformanceResourceTiming interface is a serializer; it returns a JSON representation of the PerformanceResourceTiming object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceResourceTiming/toJSON)
     */
    toJSON(): any;
}

declare var PerformanceResourceTiming: {
    prototype: PerformanceResourceTiming;
    new(): PerformanceResourceTiming;
};

/**
 * The **`PerformanceServerTiming`** interface surfaces server metrics that are sent with the response in the Server-Timing HTTP header.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceServerTiming)
 */
interface PerformanceServerTiming {
    /**
     * The **`description`** read-only property returns a string value of the server-specified metric description, or an empty string.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceServerTiming/description)
     */
    readonly description: string;
    /**
     * The **`duration`** read-only property returns a double that contains the server-specified metric duration (usually in milliseconds), or the value 0.0.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceServerTiming/duration)
     */
    readonly duration: DOMHighResTimeStamp;
    /**
     * The **`name`** read-only property returns a string value of the server-specified metric name.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceServerTiming/name)
     */
    readonly name: string;
    /**
     * The **`toJSON()`** method of the PerformanceServerTiming interface is a serializer; it returns a JSON representation of the PerformanceServerTiming object.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceServerTiming/toJSON)
     */
    toJSON(): any;
}

declare var PerformanceServerTiming: {
    prototype: PerformanceServerTiming;
    new(): PerformanceServerTiming;
};

/**
 * The **`PerformanceTiming`** interface is a legacy interface kept for backwards compatibility and contains properties that offer performance timing information for various events which occur during the loading and use of the current page. You get a PerformanceTiming object describing your page using the window.performance.timing property.
 * @deprecated This interface is deprecated in the Navigation Timing Level 2 specification. Please use the PerformanceNavigationTiming interface instead.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming)
 */
interface PerformanceTiming {
    /**
     * The legacy **`PerformanceTiming.connectEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, where the connection is opened network. If the transport layer reports an error and the connection establishment is started again, the last connection establishment end time is given. If a persistent connection is used, the value will be the same as PerformanceTiming.fetchStart. A connection is considered as opened when all secure connection handshake, or SOCKS authentication, is terminated.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/connectEnd)
     */
    readonly connectEnd: number;
    /**
     * The legacy **`PerformanceTiming.connectStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, where the request to open a connection is sent to the network. If the transport layer reports an error and the connection establishment is started again, the last connection establishment start time is given. If a persistent connection is used, the value will be the same as PerformanceTiming.fetchStart.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/connectStart)
     */
    readonly connectStart: number;
    /**
     * The legacy **`PerformanceTiming.domComplete`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the parser finished its work on the main document, that is when its Document.readyState changes to 'complete' and the corresponding readystatechange event is thrown.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domComplete)
     */
    readonly domComplete: number;
    /**
     * The legacy **`PerformanceTiming.domContentLoadedEventEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, right after all the scripts that need to be executed as soon as possible, in order or not, has been executed.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domContentLoadedEventEnd)
     */
    readonly domContentLoadedEventEnd: number;
    /**
     * The legacy **`PerformanceTiming.domContentLoadedEventStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, right before the parser sent the DOMContentLoaded event, that is right after all the scripts that need to be executed right after parsing has been executed.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domContentLoadedEventStart)
     */
    readonly domContentLoadedEventStart: number;
    /**
     * The legacy **`PerformanceTiming.domInteractive`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the parser finished its work on the main document, that is when its Document.readyState changes to 'interactive' and the corresponding readystatechange event is thrown.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domInteractive)
     */
    readonly domInteractive: number;
    /**
     * The legacy **`PerformanceTiming.domLoading`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the parser started its work, that is when its Document.readyState changes to 'loading' and the corresponding readystatechange event is thrown.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domLoading)
     */
    readonly domLoading: number;
    /**
     * The legacy **`PerformanceTiming.domainLookupEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, where the domain lookup is finished. If a persistent connection is used, or the information is stored in a cache or a local resource, the value will be the same as PerformanceTiming.fetchStart.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domainLookupEnd)
     */
    readonly domainLookupEnd: number;
    /**
     * The legacy **`PerformanceTiming.domainLookupStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, where the domain lookup starts. If a persistent connection is used, or the information is stored in a cache or a local resource, the value will be the same as PerformanceTiming.fetchStart.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/domainLookupStart)
     */
    readonly domainLookupStart: number;
    /**
     * The legacy **`PerformanceTiming.fetchStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, the browser is ready to fetch the document using an HTTP request. This moment is before the check to any application cache.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/fetchStart)
     */
    readonly fetchStart: number;
    /**
     * The legacy **`PerformanceTiming.loadEventEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the load event handler terminated, that is when the load event is completed. If this event has not yet been sent, or is not yet completed, it returns 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/loadEventEnd)
     */
    readonly loadEventEnd: number;
    /**
     * The legacy **`PerformanceTiming.loadEventStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the load event was sent for the current document. If this event has not yet been sent, it returns 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/loadEventStart)
     */
    readonly loadEventStart: number;
    /**
     * The legacy **`PerformanceTiming.navigationStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, right after the prompt for unload terminates on the previous document in the same browsing context. If there is no previous document, this value will be the same as PerformanceTiming.fetchStart.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/navigationStart)
     */
    readonly navigationStart: number;
    /**
     * The legacy **`PerformanceTiming.redirectEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, the last HTTP redirect is completed, that is when the last byte of the HTTP response has been received. If there is no redirect, or if one of the redirect is not of the same origin, the value returned is 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/redirectEnd)
     */
    readonly redirectEnd: number;
    /**
     * The legacy **`PerformanceTiming.redirectStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, the first HTTP redirect starts. If there is no redirect, or if one of the redirect is not of the same origin, the value returned is 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/redirectStart)
     */
    readonly redirectStart: number;
    /**
     * The legacy **`PerformanceTiming.requestStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the browser sent the request to obtain the actual document, from the server or from a cache. If the transport layer fails after the start of the request and the connection is reopened, this property will be set to the time corresponding to the new request.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/requestStart)
     */
    readonly requestStart: number;
    /**
     * The legacy **`PerformanceTiming.responseEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, when the browser received the last byte of the response, or when the connection is closed if this happened first, from the server from a cache or from a local resource.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/responseEnd)
     */
    readonly responseEnd: number;
    /**
     * The legacy **`PerformanceTiming.responseStart`** read-only property returns an unsigned long long representing the moment in time (in milliseconds since the UNIX epoch) when the browser received the first byte of the response from the server, cache, or local resource.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/responseStart)
     */
    readonly responseStart: number;
    /**
     * The legacy **`PerformanceTiming.secureConnectionStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, where the secure connection handshake starts. If no such connection is requested, it returns 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/secureConnectionStart)
     */
    readonly secureConnectionStart: number;
    /**
     * The legacy **`PerformanceTiming.unloadEventEnd`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, the unload event handler finishes. If there is no previous document, or if the previous document, or one of the needed redirects, is not of the same origin, the value returned is 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/unloadEventEnd)
     */
    readonly unloadEventEnd: number;
    /**
     * The legacy **`PerformanceTiming.unloadEventStart`** read-only property returns an unsigned long long representing the moment, in milliseconds since the UNIX epoch, the unload event has been thrown. If there is no previous document, or if the previous document, or one of the needed redirects, is not of the same origin, the value returned is 0.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/unloadEventStart)
     */
    readonly unloadEventStart: number;
    /**
     * The legacy **`toJSON()`** method of the PerformanceTiming interface is a serializer; it returns a JSON representation of the PerformanceTiming object.
     * @deprecated
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PerformanceTiming/toJSON)
     */
    toJSON(): any;
}

/** @deprecated */
declare var PerformanceTiming: {
    prototype: PerformanceTiming;
    new(): PerformanceTiming;
};

/**
 * The **`PeriodicWave`** interface defines a periodic waveform that can be used to shape the output of an OscillatorNode.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PeriodicWave)
 */
interface PeriodicWave {
}

declare var PeriodicWave: {
    prototype: PeriodicWave;
    new(context: BaseAudioContext, options?: PeriodicWaveOptions): PeriodicWave;
};

interface PermissionStatusEventMap {
    "change": Event;
}

/**
 * The **`PermissionStatus`** interface of the Permissions API provides the state of an object and an event handler for monitoring changes to said state.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PermissionStatus)
 */
interface PermissionStatus extends EventTarget {
    /**
     * The **`name`** read-only property of the PermissionStatus interface returns the name of a requested permission.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PermissionStatus/name)
     */
    readonly name: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/PermissionStatus/change_event) */
    onchange: ((this: PermissionStatus, ev: Event) => any) | null;
    /**
     * The **`state`** read-only property of the PermissionStatus interface returns the state of a requested permission. This property returns one of 'granted', 'denied', or 'prompt'.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PermissionStatus/state)
     */
    readonly state: PermissionState;
    addEventListener<K extends keyof PermissionStatusEventMap>(type: K, listener: (this: PermissionStatus, ev: PermissionStatusEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof PermissionStatusEventMap>(type: K, listener: (this: PermissionStatus, ev: PermissionStatusEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var PermissionStatus: {
    prototype: PermissionStatus;
    new(): PermissionStatus;
};

/**
 * The **`Permissions`** interface of the Permissions API provides the core Permission API functionality, such as methods for querying and revoking permissions
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Permissions)
 */
interface Permissions {
    /**
     * The **`query()`** method of the Permissions interface returns the state of a user permission on the global scope.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Permissions/query)
     */
    query(permissionDesc: PermissionDescriptor): Promise<PermissionStatus>;
}

declare var Permissions: {
    prototype: Permissions;
    new(): Permissions;
};

/**
 * The **`PictureInPictureEvent`** interface represents picture-in-picture-related events, including enterpictureinpicture, leavepictureinpicture and resize.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PictureInPictureEvent)
 */
interface PictureInPictureEvent extends Event {
    /**
     * The read-only **`pictureInPictureWindow`** property of the PictureInPictureEvent interface returns the PictureInPictureWindow the event relates to.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PictureInPictureEvent/pictureInPictureWindow)
     */
    readonly pictureInPictureWindow: PictureInPictureWindow;
}

declare var PictureInPictureEvent: {
    prototype: PictureInPictureEvent;
    new(type: string, eventInitDict: PictureInPictureEventInit): PictureInPictureEvent;
};

interface PictureInPictureWindowEventMap {
    "resize": Event;
}

/**
 * The **`PictureInPictureWindow`** interface represents an object able to programmatically obtain the width and height and resize event of the floating video window.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PictureInPictureWindow)
 */
interface PictureInPictureWindow extends EventTarget {
    /**
     * The read-only **`height`** property of the PictureInPictureWindow interface returns the height of the floating video window in pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PictureInPictureWindow/height)
     */
    readonly height: number;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/PictureInPictureWindow/resize_event) */
    onresize: ((this: PictureInPictureWindow, ev: Event) => any) | null;
    /**
     * The read-only **`width`** property of the PictureInPictureWindow interface returns the width of the floating video window in pixels.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PictureInPictureWindow/width)
     */
    readonly width: number;
    addEventListener<K extends keyof PictureInPictureWindowEventMap>(type: K, listener: (this: PictureInPictureWindow, ev: PictureInPictureWindowEventMap[K]) => any, options?: boolean | AddEventListenerOptions): void;
    addEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions): void;
    removeEventListener<K extends keyof PictureInPictureWindowEventMap>(type: K, listener: (this: PictureInPictureWindow, ev: PictureInPictureWindowEventMap[K]) => any, options?: boolean | EventListenerOptions): void;
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions): void;
}

declare var PictureInPictureWindow: {
    prototype: PictureInPictureWindow;
    new(): PictureInPictureWindow;
};

/**
 * The **`Plugin`** interface provides information about a browser plugin.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/Plugin)
 */
interface Plugin {
    /**
     * Returns the plugin's description.
     * @deprecated
     */
    readonly description: string;
    /**
     * Returns the plugin library's filename, if applicable on the current platform.
     * @deprecated
     */
    readonly filename: string;
    /**
     * Returns the number of MIME types, represented by MimeType objects, supported by the plugin.
     * @deprecated
     */
    readonly length: number;
    /**
     * Returns the plugin's name.
     * @deprecated
     */
    readonly name: string;
    /**
     * Returns the specified MimeType object.
     * @deprecated
     */
    item(index: number): MimeType | null;
    /** @deprecated */
    namedItem(name: string): MimeType | null;
    [index: number]: MimeType;
}

/** @deprecated */
declare var Plugin: {
    prototype: Plugin;
    new(): Plugin;
};

/**
 * The **`PluginArray`** interface is used to store a list of Plugin objects; it's returned by the navigator.plugins property. The PluginArray is not a JavaScript array, but has the length property and supports accessing individual items using bracket notation (plugins[2]), as well as via item(index) and namedItem("name") methods.
 * @deprecated
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PluginArray)
 */
interface PluginArray {
    /** @deprecated */
    readonly length: number;
    /** @deprecated */
    item(index: number): Plugin | null;
    /** @deprecated */
    namedItem(name: string): Plugin | null;
    /** @deprecated */
    refresh(): void;
    [index: number]: Plugin;
}

/** @deprecated */
declare var PluginArray: {
    prototype: PluginArray;
    new(): PluginArray;
};

/**
 * The **`PointerEvent`** interface represents the state of a DOM event produced by a pointer such as the geometry of the contact point, the device type that generated the event, the amount of pressure that was applied on the contact surface, etc.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent)
 */
interface PointerEvent extends MouseEvent {
    /**
     * The **`altitudeAngle`** read-only property of the PointerEvent interface represents the angle between a transducer (a pointer or stylus) axis and the X-Y plane of a device screen. The altitude angle describes whether the transducer is perpendicular to the screen, parallel, or at some angle in between.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/altitudeAngle)
     */
    readonly altitudeAngle: number;
    /**
     * The **`azimuthAngle`** read-only property of the PointerEvent interface represents the angle between the Y-Z plane and the plane containing both the transducer (pointer or stylus) axis and the Y axis.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/azimuthAngle)
     */
    readonly azimuthAngle: number;
    /**
     * The **`height`** read-only property of the PointerEvent interface represents the height of the pointer's contact geometry, along the y-axis (in CSS pixels). Depending on the source of the pointer device (for example a finger), for a given pointer, each event may produce a different value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/height)
     */
    readonly height: number;
    /**
     * The **`isPrimary`** read-only property of the PointerEvent interface indicates whether or not the pointer device that created the event is the primary pointer. It returns true if the pointer that caused the event to be fired is the primary one and returns false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/isPrimary)
     */
    readonly isPrimary: boolean;
    /**
     * The **`persistentDeviceId`** read-only property of the PointerEvent interface is a unique identifier for the pointing device generating the PointerEvent. This provides a secure, reliable way to identify multiple pointing devices (such as pens) interacting with the screen simultaneously.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/persistentDeviceId)
     */
    readonly persistentDeviceId: number;
    /**
     * The **`pointerId`** read-only property of the PointerEvent interface is an identifier assigned to the pointer that triggered the event. The identifier is unique, being different from the identifiers of all other active pointer events.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/pointerId)
     */
    readonly pointerId: number;
    /**
     * The **`pointerType`** read-only property of the PointerEvent interface indicates the device type (mouse, pen, or touch) that caused a given pointer event.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/pointerType)
     */
    readonly pointerType: string;
    /**
     * The **`pressure`** read-only property of the PointerEvent interface indicates the normalized pressure of the pointer input.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/pressure)
     */
    readonly pressure: number;
    /**
     * The **`tangentialPressure`** read-only property of the PointerEvent interface represents the normalized tangential pressure of the pointer input (also known as barrel pressure or cylinder stress).
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/tangentialPressure)
     */
    readonly tangentialPressure: number;
    /**
     * The **`tiltX`** read-only property of the PointerEvent interface is the angle (in degrees) between the Y-Z plane of the pointer and the screen. This property is typically only useful for a pen/stylus pointer type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/tiltX)
     */
    readonly tiltX: number;
    /**
     * The **`tiltY`** read-only property of the PointerEvent interface is the angle (in degrees) between the X-Z plane of the pointer and the screen. This property is typically only useful for a pen/stylus pointer type.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/tiltY)
     */
    readonly tiltY: number;
    /**
     * The **`twist`** read-only property of the PointerEvent interface represents the clockwise rotation of the pointer (e.g., pen stylus) around its major axis, in degrees.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/twist)
     */
    readonly twist: number;
    /**
     * The **`width`** read-only property of the PointerEvent interface represents the width of the pointer's contact geometry along the x-axis, measured in CSS pixels. Depending on the source of the pointer device (such as a finger), for a given pointer, each event may produce a different value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/width)
     */
    readonly width: number;
    /**
     * The **`getCoalescedEvents()`** method of the PointerEvent interface returns a sequence of PointerEvent instances that were coalesced (merged) into a single pointermove or pointerrawupdate event. Instead of a stream of many pointermove events, user agents coalesce multiple updates into a single event. This helps with performance as the user agent has less event handling to perform, but there is a reduction in the granularity and accuracy when tracking, especially with fast and large movements.
     * Available only in secure contexts.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/getCoalescedEvents)
     */
    getCoalescedEvents(): PointerEvent[];
    /**
     * The **`getPredictedEvents()`** method of the PointerEvent interface returns a sequence of PointerEvent instances that are estimated future pointer positions. How the predicted positions are calculated depends on the user agent, but they are based on past points, current velocity, and trajectory.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PointerEvent/getPredictedEvents)
     */
    getPredictedEvents(): PointerEvent[];
}

declare var PointerEvent: {
    prototype: PointerEvent;
    new(type: string, eventInitDict?: PointerEventInit): PointerEvent;
};

/**
 * **`PopStateEvent`** is an interface for the popstate event.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PopStateEvent)
 */
interface PopStateEvent extends Event {
    /**
     * The **`hasUAVisualTransition`** read-only property of the PopStateEvent interface returns true if the user agent performed a visual transition for this navigation before dispatching this event, or false otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PopStateEvent/hasUAVisualTransition)
     */
    readonly hasUAVisualTransition: boolean;
    /**
     * The **`state`** read-only property of the PopStateEvent interface represents the state stored when the event was created.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PopStateEvent/state)
     */
    readonly state: any;
}

declare var PopStateEvent: {
    prototype: PopStateEvent;
    new(type: string, eventInitDict?: PopStateEventInit): PopStateEvent;
};

interface PopoverTargetAttributes {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/popoverTargetAction) */
    popoverTargetAction: string;
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/HTMLButtonElement/popoverTargetElement) */
    popoverTargetElement: Element | null;
}

/**
 * The **`ProcessingInstruction`** interface represents a processing instruction; that is, a Node which embeds an instruction targeting a specific application but that can be ignored by any other applications which don't recognize the instruction.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ProcessingInstruction)
 */
interface ProcessingInstruction extends CharacterData, LinkStyle {
    /**
     * The read-only **`target`** property of the ProcessingInstruction interface represent the application to which the ProcessingInstruction is targeted.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ProcessingInstruction/target)
     */
    readonly target: string;
}

declare var ProcessingInstruction: {
    prototype: ProcessingInstruction;
    new(): ProcessingInstruction;
};

/**
 * The **`ProgressEvent`** interface represents events that measure the progress of an underlying process, like an HTTP request (e.g., an XMLHttpRequest, or the loading of the underlying resource of an <img>, <audio>, <video>, <style> or <link>).
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ProgressEvent)
 */
interface ProgressEvent<T extends EventTarget = EventTarget> extends Event {
    /**
     * The **`ProgressEvent.lengthComputable`** read-only property is a boolean flag indicating if the resource concerned by the ProgressEvent has a length that can be calculated. If not, the ProgressEvent.total property has no significant value.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ProgressEvent/lengthComputable)
     */
    readonly lengthComputable: boolean;
    /**
     * The **`ProgressEvent.loaded`** read-only property is a number indicating the size of the data already transmitted or processed. The progress ratio can be calculated by dividing the value of this property by ProgressEvent.total.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ProgressEvent/loaded)
     */
    readonly loaded: number;
    readonly target: T | null;
    /**
     * The **`ProgressEvent.total`** read-only property is a number indicating the total size of the data being transmitted or processed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/ProgressEvent/total)
     */
    readonly total: number;
}

declare var ProgressEvent: {
    prototype: ProgressEvent;
    new(type: string, eventInitDict?: ProgressEventInit): ProgressEvent;
};

/**
 * The **`PromiseRejectionEvent`** interface represents events which are sent to the global script context when JavaScript Promises are rejected. These events are particularly useful for telemetry and debugging purposes.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PromiseRejectionEvent)
 */
interface PromiseRejectionEvent extends Event {
    /**
     * The PromiseRejectionEvent interface's **`promise`** read-only property indicates the JavaScript Promise which was rejected. You can examine the event's PromiseRejectionEvent.reason property to learn why the promise was rejected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PromiseRejectionEvent/promise)
     */
    readonly promise: Promise<any>;
    /**
     * The PromiseRejectionEvent **`reason`** read-only property is any JavaScript value or Object which provides the reason passed into Promise.reject(). This in theory provides information about why the promise was rejected.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PromiseRejectionEvent/reason)
     */
    readonly reason: any;
}

declare var PromiseRejectionEvent: {
    prototype: PromiseRejectionEvent;
    new(type: string, eventInitDict: PromiseRejectionEventInit): PromiseRejectionEvent;
};

/**
 * The **`PublicKeyCredential`** interface provides information about a public key / private key pair, which is a credential for logging in to a service using an un-phishable and data-breach resistant asymmetric key pair instead of a password. It inherits from Credential, and is part of the Web Authentication API extension to the Credential Management API.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential)
 */
interface PublicKeyCredential extends Credential {
    /**
     * The **`authenticatorAttachment`** read-only property of the PublicKeyCredential interface is a string that indicates the general category of authenticator used during the associated navigator.credentials.create() or navigator.credentials.get() call.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/authenticatorAttachment)
     */
    readonly authenticatorAttachment: string | null;
    /**
     * The **`rawId`** read-only property of the PublicKeyCredential interface is an ArrayBuffer object containing the identifier of the credentials.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/rawId)
     */
    readonly rawId: ArrayBuffer;
    /**
     * The **`response`** read-only property of the PublicKeyCredential interface is an AuthenticatorResponse object which is sent from the authenticator to the user agent for the creation/fetching of credentials. The information contained in this response will be used by the relying party's server to verify the demand is legitimate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/response)
     */
    readonly response: AuthenticatorResponse;
    /**
     * The **`getClientExtensionResults()`** method of the PublicKeyCredential interface returns an object mapping the identifiers of extensions requested during credential creation or authentication, and their results after processing by the user agent.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/getClientExtensionResults)
     */
    getClientExtensionResults(): AuthenticationExtensionsClientOutputs;
    /**
     * The **`toJSON()`** method of the PublicKeyCredential interface returns a JSON type representation of a PublicKeyCredential.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/toJSON)
     */
    toJSON(): RegistrationResponseJSON | AuthenticationResponseJSON;
}

declare var PublicKeyCredential: {
    prototype: PublicKeyCredential;
    new(): PublicKeyCredential;
    /**
     * The **`getClientCapabilities()`** static method of the PublicKeyCredential interface returns a Promise that resolves with an object that can be used to check whether or not particular WebAuthn client capabilities and extensions are supported.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/getClientCapabilities_static)
     */
    getClientCapabilities(): Promise<PublicKeyCredentialClientCapabilities>;
    /**
     * The **`isConditionalMediationAvailable()`** static method of the PublicKeyCredential interface returns a Promise which resolves to true if conditional mediation is available.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/isConditionalMediationAvailable_static)
     */
    isConditionalMediationAvailable(): Promise<boolean>;
    /**
     * The **`isUserVerifyingPlatformAuthenticatorAvailable()`** static method of the PublicKeyCredential interface returns a Promise which resolves to true if a user-verifying platform authenticator is present.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/isUserVerifyingPlatformAuthenticatorAvailable_static)
     */
    isUserVerifyingPlatformAuthenticatorAvailable(): Promise<boolean>;
    /**
     * The **`parseCreationOptionsFromJSON()`** static method of the PublicKeyCredential interface creates a PublicKeyCredentialCreationOptions object from a JSON representation of its properties.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/parseCreationOptionsFromJSON_static)
     */
    parseCreationOptionsFromJSON(options: PublicKeyCredentialCreationOptionsJSON): PublicKeyCredentialCreationOptions;
    /**
     * The **`parseRequestOptionsFromJSON()`** static method of the PublicKeyCredential interface converts a JSON type representation into a PublicKeyCredentialRequestOptions instance.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/parseRequestOptionsFromJSON_static)
     */
    parseRequestOptionsFromJSON(options: PublicKeyCredentialRequestOptionsJSON): PublicKeyCredentialRequestOptions;
    /**
     * The **`signalAllAcceptedCredentials()`** static method of the PublicKeyCredential interface signals to the authenticator all of the valid credential IDs that the relying party (RP) server still holds for a particular user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/signalAllAcceptedCredentials_static)
     */
    signalAllAcceptedCredentials(options: AllAcceptedCredentialsOptions): Promise<void>;
    /**
     * The **`signalCurrentUserDetails()`** static method of the PublicKeyCredential interface signals to the authenticator that a particular user has updated their user name and/or display name on the relying party (RP) server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/signalCurrentUserDetails_static)
     */
    signalCurrentUserDetails(options: CurrentUserDetailsOptions): Promise<void>;
    /**
     * The **`signalUnknownCredential()`** static method of the PublicKeyCredential interface signals to the authenticator that a credential ID was not recognized by the relying party (RP) server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PublicKeyCredential/signalUnknownCredential_static)
     */
    signalUnknownCredential(options: UnknownCredentialOptions): Promise<void>;
};

/**
 * The **`PushManager`** interface of the Push API provides a way to receive notifications from third-party servers as well as request URLs for push notifications.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushManager)
 */
interface PushManager {
    /**
     * The **`PushManager.getSubscription()`** method of the PushManager interface retrieves an existing push subscription.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushManager/getSubscription)
     */
    getSubscription(): Promise<PushSubscription | null>;
    /**
     * The **`permissionState()`** method of the PushManager interface returns a Promise that resolves to a string indicating the permission state of the push manager. Possible values are 'prompt', 'denied', or 'granted'.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushManager/permissionState)
     */
    permissionState(options?: PushSubscriptionOptionsInit): Promise<PermissionState>;
    /**
     * The **`subscribe()`** method of the PushManager interface subscribes to a push service.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushManager/subscribe)
     */
    subscribe(options?: PushSubscriptionOptionsInit): Promise<PushSubscription>;
}

declare var PushManager: {
    prototype: PushManager;
    new(): PushManager;
    /**
     * The **`supportedContentEncodings`** read-only static property of the PushManager interface returns an array of supported content codings that can be used to encrypt the payload of a push message.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushManager/supportedContentEncodings_static)
     */
    readonly supportedContentEncodings: ReadonlyArray<string>;
};

/** Available only in secure contexts. */
interface PushManagerAttribute {
    /** [MDN Reference](https://developer.mozilla.org/docs/Web/API/ServiceWorkerRegistration/pushManager) */
    readonly pushManager: PushManager;
}

/**
 * The **`PushSubscription`** interface of the Push API provides a subscription's URL endpoint along with the public key and secrets that should be used for encrypting push messages to this subscription. This information must be passed to the application server, using any desired application-specific method.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription)
 */
interface PushSubscription {
    /**
     * The **`endpoint`** read-only property of the PushSubscription interface returns a string containing the endpoint associated with the push subscription.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription/endpoint)
     */
    readonly endpoint: string;
    /**
     * The **`expirationTime`** read-only property of the PushSubscription interface returns a DOMHighResTimeStamp of the subscription expiration time associated with the push subscription, if there is one, or null otherwise.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription/expirationTime)
     */
    readonly expirationTime: EpochTimeStamp | null;
    /**
     * The **`options`** read-only property of the PushSubscription interface is an object containing the options used to create the subscription.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription/options)
     */
    readonly options: PushSubscriptionOptions;
    /**
     * The **`getKey()`** method of the PushSubscription interface returns an ArrayBuffer representing a client public key, which can then be sent to a server and used in encrypting push message data.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription/getKey)
     */
    getKey(name: PushEncryptionKeyName): ArrayBuffer | null;
    /**
     * The **`toJSON()`** method of the PushSubscription interface is a standard serializer: it returns a JSON representation of the subscription properties, providing a useful shortcut.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription/toJSON)
     */
    toJSON(): PushSubscriptionJSON;
    /**
     * The **`unsubscribe()`** method of the PushSubscription interface returns a Promise that resolves to a boolean value when the current subscription is successfully unsubscribed.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscription/unsubscribe)
     */
    unsubscribe(): Promise<boolean>;
}

declare var PushSubscription: {
    prototype: PushSubscription;
    new(): PushSubscription;
};

/**
 * The **`PushSubscriptionOptions`** interface of the Push API represents the options associated with a push subscription.
 * Available only in secure contexts.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscriptionOptions)
 */
interface PushSubscriptionOptions {
    /**
     * The **`applicationServerKey`** read-only property of the PushSubscriptionOptions interface contains the public key used by the push server.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscriptionOptions/applicationServerKey)
     */
    readonly applicationServerKey: ArrayBuffer | null;
    /**
     * The **`userVisibleOnly`** read-only property of the PushSubscriptionOptions interface indicates if the returned push subscription will only be used for messages whose effect is made visible to the user.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/PushSubscriptionOptions/userVisibleOnly)
     */
    readonly userVisibleOnly: boolean;
}

declare var PushSubscriptionOptions: {
    prototype: PushSubscriptionOptions;
    new(): PushSubscriptionOptions;
};

/**
 * The **`RTCCertificate`** interface of the WebRTC API provides an object representing a certificate that an RTCPeerConnection uses to authenticate.
 *
 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCCertificate)
 */
interface RTCCertificate {
    /**
     * The read-only **`expires`** property of the RTCCertificate interface returns the expiration date of the certificate.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCCertificate/expires)
     */
    readonly expires: EpochTimeStamp;
    /**
     * The **`getFingerprints()`** method of the RTCCertificate interface is used to get an array of certificate fingerprints.
     *
     * [MDN Reference](https://developer.mozilla.org/docs/Web/API/RTCCertificate/getFingerprints)
     */
    getFingerprints(): RTCDtlsFingerprint[];
}

declare var RTCCertificate: {
    prototype: RTCCertificate;
    new(): RTCCertificate;
};

interface RTCDTMFSenderEventMap {
    "tonechange": RTCDTMFToneChangeEvent;
}
