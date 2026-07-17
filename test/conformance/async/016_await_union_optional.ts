// `await` distributes over unions: awaiting `Promise<T> | undefined` yields
// `T | undefined` (common now that optional chains produce `... | undefined`).
interface Server { getPrimaryService(id: string): Promise<number>; }
declare const dev: { gatt?: { connect(): Promise<Server> } };

async function connect(): Promise<number> {
  const server = await dev.gatt?.connect(); // Server | undefined
  if (!server) throw new Error("no server");
  return server.getPrimaryService("x");
}

void connect;
