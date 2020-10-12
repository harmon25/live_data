/**
 * LiveData JavaScript client TODO - More docs..
 *
 * ## Connection
 *
 * A single connection is established to the server....
 *
 * ```javascript
 * let ldSocket = new LiveDataSocket({params: {userToken: "123"}})
 * ```
 *
 */
import { applyPatch } from "fast-json-patch";
import debounce from "lodash.debounce";
import localforage from "localforage";
// import produce, { applyPatches, enablePatches } from "immer";
// import clonedeep from "lodash.clonedeep";

/**
 * LiveDataOpts class constructor Opts
 * @typedef {Object} LiveData
 * @property {path} path - Path to connect to socket, defaults to `/live_data_socket`
 * @property {Object} params - socket connect params
 * @property {string} sessionId - auto generated uuidv4 if not provided.
 * @property {Socket} socket - Just a passed in socket.
 */
//
export function uuid() {
  return uuidv4();
}

const storageKeyPrefix = "__LD_";
const sessioIdKey = "__LD_SESSION_KEY_";
const ALREADY_REGISTERED = "already_registered";
// const session_id_key = ;

// let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// {params: {_csrf_token: csrfToken}}

/** Class for LiveData socket singleton - should only be one of these in the app.
 * @param {string} endPoint - The string WebSocket endpoint, ie, `"wss://example.com/live"`,
 *                                               `"/live"` (inherited host & protocol)
 *
 * @param {Phoenix.Socket} socket - the required Phoenix Socket class imported from "phoenix". For example:
 *
 * @param {Object} [opts] - Optional configuration. Outside of keys listed below, all
 */
export class LiveDataSocket {
  // unsure if we should be storing anything in memory here?
  static _stateStore = {};
  static _registry = {};
  /**
   * Create a LiveData Instance
   * @param {LiveDataOpts} opts
   */
  constructor(url, phxSocket, opts = {}) {
    console.log("Constructing LiveData Instance.");
    if (!phxSocket || phxSocket.constructor.name === "Object") {
      throw new Error(`
      a phoenix Socket must be provided as the second argument to the LiveDataSocket constructor. For example:
          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"
          let liveSocket = new LiveSocket("/live", Socket, {...})
      `);
    }

    this.socket = new phxSocket(url, opts);
    // create + store a sessionId for this instance -

    // key value {name: defaultState}, used to hydrate the default state for a component.
    // could possibly be overridden when 'registering'
    this.defaultStates = opts.defaultStates || {};
    this.socket.connect();
  }

  _statePersistor = (uuid) => {
    return debounce(
      () =>
        localforage.setItem(
          this._storageKeyPrefix + uuid,
          this._stateStore[uuid]
        ),
      250
      // { trailing: true }
    );
  };

  // this is used to load persisted state from the client.
  // localforage uses promise bases api for access to IndexDB - which can store more than just json
  // https://localforage.github.io/localForage/#data-api-setitem
  async load() {
    // grab all keys from localforage
    const keys = await localforage.keys();
    // filter out the live_data keys.
    const liveDataKeys = keys.filter((k) =>
      k.startsWith(this._storageKeyPrefix)
    );
    // enumerate keys, and set current state.
    let current, withoutPrefix, result;
    for (let i = 0; i < liveDataKeys.length; i++) {
      current = liveDataKeys[i];
      withoutPrefix = current.slice(this._storageKeyPrefix.length);
      result = await localforage.getItem(current);
      this._stateStore[withoutPrefix] = result;
    }
  }

  // gets default state or an empty object.
  getDefaultState = (name) => {
    return this.defaultStates[name] || {};
  };

  getCurrentState = (uuid) => {
    return (
      this._stateStore[uuid] || this.defaultStates[uuid.split(":")[0]] || {}
    );
  };

  getChannelState(uuid) {
    return this._registry[uuid] && this._registry[uuid].channel.state;
  }

  // generates a diff function unique per instance in the registry.
  // stores result of applied patch in registry[instanceId].state
  _handleDiff = (uuid) => ({ diff }) => {
    var { newDocument } = applyPatch(
      this._stateStore[uuid],
      diff,
      false,
      false
    );
    this._stateStore[uuid] = newDocument;
    // if a persistor is defined = run debounced persist fn.
    this._registry[uuid].persistor && this._registry[uuid].persistor();
  };

  // registers the live data instance
  // Idempotent, and can be run multiple times
  register = (opts) => {
    let name = opts.name;
    let persist = opts.persist || false;
    let id = opts.id || this.sessionId;
    let instanceId = `${name}:${id}`;
    let connectParams = opts.connectParams || {};

    let providedDefaultState = opts.defaultState || this.getDefaultState(name);

    let thisInstance = this._registry[instanceId]
      ? this._registry[instanceId]
      : {
          opts: { persist },
          name,
          channel: null,
          persistor: persist ? this._statePersistor(instanceId) : null,
        };

    connectParams = thisInstance.opts.persist
      ? {
          prevState: this._stateStore[instanceId],
          ...connectParams,
        }
      : connectParams;

    if (
      thisInstance.channel === null ||
      thisInstance.channel.state === "closed"
    ) {
      thisInstance.channel = this.socket.channel(instanceId, connectParams);
      thisInstance.channel.on("diff", this._handleDiff(instanceId));
      thisInstance.channel.on("replace", ({ newState }) => {
        this._stateStore[instanceId] = newState;
      });
    }

    thisInstance.cb = {
      afterConnect: thisInstance.cb.afterConnect
        ? thisInstance.cb.afterConnect
        : opts.afterConnect,
      beforeDisconnect: thisInstance.cb.beforeDisconnect
        ? thisInstance.cb.beforeDisconnect
        : opts.beforeDisconnect,
    };

    this._registry[instanceId] = thisInstance;
    return thisInstance;
  };

  /**
   * Connects channel, hydrates updated to state from server, resolves with registered state
   * relies in phoenix channel join idempotentency
   * @param {string} uuid
   */
  connect = (uuid) => {
    let instance = this.registry[uuid];
    return new Promise((resolve, reject) => {
      if (instance && instance.channel.state === "closed") {
        instance.channel
          .join()
          .receive("ok", (resp) => {
            instance.cb.afterConnect && instance.cb.afterConnect(resp);
            resolve(resp);
          })
          .receive("error", reject);
      } else if (!instance) {
        reject(`${uuid} does not exist in registry`);
      } else {
        console.log(
          `instance channel state not closed...(${instance.channel.state})`
        );
      }
    });
  };

  /**
   * Disconnects channel, and cleans up references.
   * If persistence is enabled this is where it persists the state, to be hydrated on reconnect.
   * @param {string} uuid
   */
  disconnect = (uuid) => {
    if (this.registry[uuid]) {
      // if (this.registry[uuid].persist) {
      //   await this.registry[uuid].persistor();
      //   console.log("persisted state for ", uuid);
      // }

      this.registry[uuid].cb.beforeDisconnect &&
        this.registry[uuid].cb.beforeDisconnect();
      // this.persistor.persist();
      this.registry[uuid].channel.leave();
      // delete this.registry[uuid];
    }

    return uuid;
  };

  /**
   * Push a message to a registered channel
   * @param {string} uuid
   * @param {string} msg
   * @param {Object} params
   */
  push = (uuid, msg, params = {}) => {
    if (
      this.registry[uuid] &&
      this.registry[uuid].channel &&
      (this.registry[uuid].channel.state === "joined" ||
        this.registry[uuid].channel.state === "joining")
    ) {
      this.registry[uuid].channel.push(msg, params);
    } else if (this.registry[uuid]) {
      console.log("Not pushing...");
      console.log(this.registry[uuid].channel);
    }
  };

  _defaultCB = (newState) => {
    console.log(newState);
  };
}

/** Class for LiveData Component instances. */
export class LiveDataOld {
  /**
   * Create a LiveData Component Instance
   * @param {LiveDataOpts} opts
   */
  constructor(opts = {}) {
    // super();
    this.state = {};
    this.onDiff = opts.onDiff || this._defaultCB;
    this.name = opts.name;
    this.id = opts.id || uuid();
    this.uuid = `${this.name}:${this.id}`;
    let context = opts.context || window;
    this.socket = opts.socket || context.LIVE_DATA_SOCKET;
    this.channel = this.socket.channel(this.uuid, opts.params);
  }

  currentState() {
    return this.state;
  }

  connect(params) {
    this.channel.join().receive("ok", (resp) => {
      console.log(`Joined ${this.uuid} successfully`, resp);
    });

    return () => {
      this.channel.leave();
    };
  }

  push = (msg, params = {}) => {
    this.channel.push(msg, params);
  };

  _defaultCB = (newState) => {
    console.log(newState);
  };
}
