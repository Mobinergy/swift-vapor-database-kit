import NIOConcurrencyHelpers

/// Holds a collection of active `DatabaseConnection`s that can be requested and later released
/// back into the pool. New connections are created as needed when a connection is requested and none
/// are available until the max limit is reached. After the maximum is reached, no new connections will
/// be created unless existing, active connections become closed.
///
///     let conn = try pool.requestConnection().wait()
///     defer { pool.releaseConnection(conn) }
///     // use the connection
///
/// Normally you will not use this type directly and you will use methods like `Container.withPooledConnection(...)` instead.
public final class DatabaseConnectionPool<Database> where Database: DatabaseKit.Database {
    // MARK: Properties

    /// The database to use for making new connections.
    public let database: Database

    /// The Worker for this pool.
    public let eventLoop: EventLoop

    /// This pool's configuration settings.
    public let config: DatabaseConnectionPoolConfig

    // MARK: Private Properties

    /// Available connections.
    private var actives: [ActiveDatabasePoolConnection<Database>]
    private var activeCount: Int = 0
    
    /// Synchronize access.
    private let lock: Lock

    /// Notified when more connections are available.
    private var waiters: [Promise<Database.Connection>]

    /// Creates a new `DatabaseConnectionPool`.
    ///
    /// Use `Database.newConnectionPool(...)`.
    internal init(config: DatabaseConnectionPoolConfig, database: Database, on worker: Worker) {
        self.database = database
        self.eventLoop = worker.eventLoop
        self.config = config
        self.actives = []
        self.waiters = []
        self.lock = .init()
    }

    // MARK: Methods

    /// Fetches a pooled connection.
    ///
    /// The connection is provided to the supplied callback and will be automatically released when the
    /// future returned by the callback is completed.
    ///
    ///     pool.withPooledConnection { conn in
    ///         // use the connection
    ///     }
    ///
    /// See `requestConnection(...)` to request a pooled connection without using a callback.
    ///
    /// - parameters:
    ///     - closure: Callback that accepts the pooled `DatabaseConnection`.
    /// - returns: A future containing the result of the closure.
    public func withConnection<T>(_ closure: @escaping (Database.Connection) throws -> Future<T>) -> Future<T> {
        let release = releaseConnection
        return requestConnection().flatMap(to: T.self) { conn in
            do {
                return try closure(conn).always { release(conn) }
            } catch {
                release(conn)

                throw error
            }
        }
    }


    /// Requests a pooled connection.
    ///
    /// The `DatabaseConnection` returned by this method should be released when you are finished using it.
    ///
    ///     let conn = try pool.requestConnection().wait()
    ///     defer { pool.releaseConnection(conn) }
    ///     // use the connection
    ///
    /// - returns: A future containing the pooled `DatabaseConnection`.
    public func requestConnection() -> Future<Database.Connection> {
        lock.lock()
        if let active = actives.first(where: { $0.isAvailable }) {
            // there is an available connection, take it
            active.isAvailable = false
            lock.unlock()

            // check if it is still open
            if !active.connection.isClosed {
                // connection is still open, we can return it directly
                return eventLoop.newSucceededFuture(result: active.connection)
            } else {
                // connection is closed, we need to replace it
                return database.newConnection(on: eventLoop).map { newConn in
                    // replace the connection with a new one
                    // this should cause the old connection to deinit now that
                    // there are no references to it
                    active.connection = newConn
                    return newConn
                }.catchMap { error in
                    // we did not manage to reopen the connection
                    // release the closed connection before failing
                    self.releaseConnection(active.connection)
                    throw error
                }
            }
        } else if activeCount < config.maxConnections  {
            // all connections are busy, but we have room to open a new connection!
            self.activeCount += 1
            lock.unlock()

            // make the new connection
            return database.newConnection(on: eventLoop).map { newConn in
                let active = ActiveDatabasePoolConnection<Database>(connection: newConn)
                self.lock.lock()
                self.actives.append(active)
                self.lock.unlock()

                return newConn
            }.catchMap { error in
                self.lock.lock()
                self.activeCount -= 1
                self.lock.unlock()

                throw error
            }
        } else {
            // connections are exhausted, we must wait for one to be returned
            let promise = eventLoop.newPromise(Database.Connection.self)
            waiters.append(promise)
            lock.unlock()
            return promise.futureResult
        }
    }

    /// Releases a connection back to the pool. Used with `requestConnection(...)`.
    ///
    ///     let conn = try pool.requestConnection().wait()
    ///     defer { pool.releaseConnection(conn) }
    ///     // use the connection
    ///
    /// - parameters:
    ///     - conn: `DatabaseConnection` to release back to the pool.
    public func releaseConnection(_ conn: Database.Connection) {
        lock.lock()

        // get the active connection for this connection
        guard let active = actives.first(where: { $0.connection === conn }) else {
            lock.unlock()
            assertionFailure("Attempted to release a connection to a pool that did not create it.")
            return
        }

        // mark it as available
        active.isAvailable = true

        // now that we know a new connection is available, we should
        // take this chance to fulfill one of the waiters
        if let waiter = waiters.popLast() {
            lock.unlock()
            requestConnection().cascade(promise: waiter)
        } else {
            lock.unlock()
        }
    }
}

// MARK: Private

/// Holds a reference to an active connection in the pool.
private final class ActiveDatabasePoolConnection<Database> where Database: DatabaseKit.Database {
    /// The actual connection. Using an IUO to allow for adding the active
    /// connection to the array before it may actually be read.
    var connection: Database.Connection

    /// `true` if the connection is not waiting to be released.
    var isAvailable: Bool

    /// Creates a new `ActiveDatabasePoolConnection`.
    init(connection: Database.Connection) {
        self.connection = connection
        self.isAvailable = false
    }
}
