//
//  ModelLibrary.swift
//  Kinetic
//
//  Turns a `ModelRegistry` id into a robot you can simulate.
//
//  Three stages, deliberately separated:
//
//    fetch(_:)     downloads a model's description and meshes into an on-disk
//                  cache. Async, network, may take a while.
//    load(_:into:) reads that cache into a `World`. Synchronous, offline, and it
//                  will never open a socket — a cached model must load on a plane.
//    validate(_:)  loads the model and reports what a user needs to know before
//                  trusting it, as data rather than as printed text, because both
//                  the CLI and Studio have to render it.
//
//  Downloads are sparse: the registry records which repository subtrees a model
//  actually needs, and only those blobs are pulled. `mujoco_menagerie` is about
//  1.9 GB of checked-in geometry; `franka_emika_panda/` is 37 MB of it, and the
//  NVIDIA Panda URDF entry is 320 KB.
//

import Foundation

// MARK: - Errors

public enum ModelLibraryError: Error, CustomStringConvertible {
    /// The id is not in the catalogue. Carries near-misses so the message can help.
    case unknownModel(id: String, suggestions: [String])
    /// `load` was asked for a model that has not been downloaded.
    case notCached(id: String, expected: URL)
    /// The download completed but the description file is absent or empty.
    case descriptionMissing(id: String, expected: URL, downloadedFiles: Int)
    /// The download produced a file that is not the format the registry claims.
    case descriptionMalformed(id: String, at: URL, detail: String)
    /// The repository listing named no files under the model's subtrees. Usually
    /// means upstream moved the directory since the registry was verified.
    case nothingToDownload(id: String, subtrees: [String])
    /// An HTTP request came back with a non-success status.
    case transport(id: String, url: URL, status: Int)
    /// Both the sparse listing and the archive fallback failed.
    case fetchFailed(id: String, sparse: String, archive: String)
    /// The archive fallback ran `tar` and it exited non-zero.
    case archiveExtractionFailed(id: String, status: Int32, detail: String)
    /// The cache directory could not be created or written.
    case cacheUnavailable(path: String, underlying: String)
    /// The importer rejected the description.
    case importFailed(id: String, at: URL, underlying: String)

    public var description: String {
        switch self {
        case .unknownModel(let id, let suggestions):
            let hint = suggestions.isEmpty
                ? "Call ModelRegistry.search(\"\(id)\") or list ModelRegistry.identifiers."
                : "Did you mean: \(suggestions.joined(separator: ", "))?"
            return "no model named '\(id)' in the registry. \(hint)"

        case .notCached(let id, let expected):
            return """
                model '\(id)' is not cached — expected the description at \(expected.path). \
                Download it first with `try await library.fetch("\(id)")`; load() is offline \
                by design and will not fetch on your behalf.
                """

        case .descriptionMissing(let id, let expected, let downloadedFiles):
            return """
                fetch of '\(id)' downloaded \(downloadedFiles) file(s) but none of them was \
                the description at \(expected.lastPathComponent). The upstream layout has \
                probably changed; check \(expected.path) and the registry entry's path.
                """

        case .descriptionMalformed(let id, let at, let detail):
            return """
                the file downloaded for '\(id)' at \(at.path) is not a valid description: \
                \(detail). Nothing was written to the cache.
                """

        case .nothingToDownload(let id, let subtrees):
            return """
                the repository listing for '\(id)' contained no files under \
                \(subtrees.joined(separator: ", ")). The upstream directory was renamed or \
                removed; the registry entry needs re-verifying.
                """

        case .transport(let id, let url, let status):
            let extra = status == 403 || status == 429
                ? " GitHub rate-limits anonymous requests; set GITHUB_TOKEN in the environment to raise the limit."
                : ""
            return "fetching '\(id)' failed: HTTP \(status) from \(url.absoluteString).\(extra)"

        case .fetchFailed(let id, let sparse, let archive):
            return """
                could not download '\(id)'. Sparse fetch failed with: \(sparse). \
                Archive fallback failed with: \(archive). Check network access to \
                github.com and codeload.github.com.
                """

        case .archiveExtractionFailed(let id, let status, let detail):
            return "extracting the archive for '\(id)' failed (tar exit \(status)): \(detail)"

        case .cacheUnavailable(let path, let underlying):
            return """
                the model cache at \(path) is not usable: \(underlying). Check the \
                directory's permissions, or construct ModelLibrary(cacheURL:) with a \
                writable location.
                """

        case .importFailed(let id, let at, let underlying):
            return """
                '\(id)' downloaded correctly but the importer rejected \(at.path): \
                \(underlying).
                """
        }
    }
}

// MARK: - Validation report

/// What a user needs to know before trusting a downloaded model.
///
/// Returned as data, never printed: the CLI renders it as a table, Studio renders
/// it as a sidebar, and tests assert on the fields.
public struct ModelValidation: Sendable, Hashable {

    /// A link and the mass its description gave it.
    public struct LinkMass: Sendable, Hashable {
        public let name: String
        public let mass: Double
    }

    // Identity, so a report can be shown without holding the entry alongside it.
    public let id: String
    public let displayName: String
    public let vendor: String
    public let format: ModelFormat
    /// SPDX identifier governing this model's files. Surfaced here as well as in
    /// the registry so a validation report is self-contained when it is exported.
    public let license: String
    /// Where the exact licence text lives upstream.
    public let licenseURL: URL
    /// Where the description itself lives upstream.
    public let sourceURL: URL

    // Structure.
    public let linkCount: Int
    /// Degrees of freedom Kinetic actually built, including a floating base.
    public let dofCount: Int
    /// Degrees of freedom the registry claims, excluding a floating base.
    public let declaredDOF: Int
    public let actuatorCount: Int
    public let geomCount: Int

    // Mass properties.
    public let totalMass: Double
    /// Movable links with effectively no mass. These make the mass matrix
    /// singular, so they are a correctness problem rather than a cosmetic one.
    public let zeroMassLinks: [String]
    /// Links whose mass is present but implausible for robot hardware.
    public let implausibleMassLinks: [LinkMass]

    // Joints.
    /// Revolute and prismatic joints with no limits. Legitimate for continuous
    /// wrists, a red flag anywhere else.
    public let unlimitedJoints: [String]

    // Geometry.
    /// Mesh references the loader could not turn into triangles, verbatim.
    public let unresolvedMeshes: [String]

    /// True when the robot's root body is free to translate and rotate.
    public let hasFloatingBase: Bool
    public var hasFixedBase: Bool { !hasFloatingBase }

    /// Human-readable problems, ordered most to least severe. Empty means the
    /// model imported cleanly.
    public let warnings: [String]

    public var isClean: Bool { warnings.isEmpty }
}

// MARK: - Library

/// Resolves registry ids to cached, loadable robots.
///
/// The type is a plain class rather than an actor: `load` and `validate` are
/// synchronous filesystem work that callers want inline, and `fetch` keeps its own
/// mutable state on the stack. Nothing here is shared mutable state.
public final class ModelLibrary: @unchecked Sendable {

    /// Root of the on-disk cache: `~/Library/Application Support/Kinetic/Models`.
    public let cacheURL: URL

    private let session: URLSession
    private let fileManager: FileManager

    /// Downloads run this many blobs at a time. Enough to saturate a link without
    /// tripping GitHub's abuse detection on a directory of two hundred meshes.
    private let maxConcurrentDownloads = 6

    /// Staging lives inside the cache so the final move is same-volume and cheap.
    private var stagingRoot: URL { cacheURL.appendingPathComponent(".staging", isDirectory: true) }

    public init(cacheURL: URL? = nil, session: URLSession = .shared,
                fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        if let cacheURL {
            self.cacheURL = cacheURL.standardizedFileURL
        } else {
            // Computed, not created — construction must not touch the disk, so a
            // read-only environment can still enumerate the registry.
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.cacheURL = support
                .appendingPathComponent("Kinetic", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .standardizedFileURL
        }
    }

    // MARK: Cache inspection

    /// Directory a model's files live in. Repository-relative paths are mirrored
    /// underneath it, so `package://` and relative mesh URIs keep working.
    public func cacheURL(for id: String) -> URL {
        cacheURL.appendingPathComponent(sanitised(id), isDirectory: true)
    }

    /// True when the model's description file is present and non-empty.
    ///
    /// Checking the description rather than the directory means an interrupted or
    /// partial fetch never reads as cached.
    public func isCached(_ id: String) -> Bool {
        guard let entry = ModelRegistry.entry(id: id) else { return false }
        let description = cacheURL(for: entry.id).appendingPathComponent(entry.path)
        guard let size = try? fileSize(of: description) else { return false }
        return size > 0
    }

    /// Every cached id, in registry order.
    public var cachedIdentifiers: [String] {
        ModelRegistry.identifiers.filter { isCached($0) }
    }

    /// Total bytes the cache occupies, staging included.
    public var cachedSize: Int64 { directorySize(cacheURL) }

    /// Bytes a single model occupies. Zero when it is not cached.
    public func cachedSize(of id: String) -> Int64 {
        directorySize(cacheURL(for: id))
    }

    /// Deletes one model. Succeeds silently when it was not there.
    public func purge(_ id: String) throws {
        let url = cacheURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ModelLibraryError.cacheUnavailable(path: url.path,
                                                     underlying: String(describing: error))
        }
    }

    /// Deletes every downloaded model and any half-finished staging directories.
    public func purgeAll() throws {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }
        do {
            try fileManager.removeItem(at: cacheURL)
        } catch {
            throw ModelLibraryError.cacheUnavailable(path: cacheURL.path,
                                                     underlying: String(describing: error))
        }
    }

    // MARK: Fetch

    /// Downloads a model's description and the meshes it references.
    ///
    /// Prefers a sparse fetch: one call to the repository's tree listing, then only
    /// the blobs under the subtrees the registry says this model needs. Falls back
    /// to the repository tarball when the listing is unavailable or truncated,
    /// which is the only other way to get the files without a full clone.
    ///
    /// Everything lands in a staging directory first. The cache is only updated
    /// once the description file is present and parses as the format the registry
    /// claims, so a failed fetch can never leave a half-model behind.
    ///
    /// - Parameter progress: called with 0...1 on the calling task as files land.
    /// - Returns: the directory the model was written to.
    @discardableResult
    public func fetch(_ id: String, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let entry = try requireEntry(id)
        let destination = cacheURL(for: entry.id)

        try createDirectory(stagingRoot)
        let staging = stagingRoot.appendingPathComponent(
            "\(entry.id)-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(staging)
        // Any exit from here on — success, throw, cancellation — must not leave a
        // staging directory behind.
        defer { try? fileManager.removeItem(at: staging) }

        progress?(0)

        var downloaded = 0
        var sparseFailure: String?
        do {
            downloaded = try await sparseFetch(entry, into: staging, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            sparseFailure = String(describing: error)
        }

        if let sparseFailure {
            do {
                // Start the fallback from a clean slate; a partial sparse fetch
                // would otherwise masquerade as extracted archive content.
                try? fileManager.removeItem(at: staging)
                try createDirectory(staging)
                downloaded = try await archiveFetch(entry, into: staging, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModelLibraryError.fetchFailed(id: entry.id, sparse: sparseFailure,
                                                    archive: String(describing: error))
            }
        }

        try verifyDescription(for: entry, in: staging, downloadedFiles: downloaded)

        // Replace rather than merge: a stale mesh from a previous layout is worse
        // than a slower re-download.
        try? fileManager.removeItem(at: destination)
        do {
            try createDirectory(destination.deletingLastPathComponent())
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw ModelLibraryError.cacheUnavailable(path: destination.path,
                                                     underlying: String(describing: error))
        }

        progress?(1)
        return destination
    }

    // MARK: Load

    /// Reads a cached model into a `World`.
    ///
    /// Offline by construction: this opens files and nothing else. Mesh search
    /// paths are wired so `package://pkg/meshes/x.stl`, `assets/x.obj` and bare
    /// `x.stl` all resolve inside the downloaded tree.
    ///
    /// - Parameter world: an existing world to add the robot to, or `nil` for a
    ///   fresh one. Passing an existing world leaves compilation to the caller,
    ///   matching `URDF.load` and `MJCF.load`.
    public func load(_ id: String, into world: World? = nil) throws -> (world: World, robot: Robot) {
        let loaded = try loadReportingWarnings(id, into: world)
        return (loaded.world, loaded.robot)
    }

    /// Loads a model and reports what a user needs to know before trusting it.
    ///
    /// Always uses a private `World` so the numbers describe this robot alone and
    /// nothing the caller happens to have in their scene.
    public func validate(_ id: String) throws -> ModelValidation {
        let entry = try requireEntry(id)
        let loaded = try loadReportingWarnings(entry.id, into: nil)
        let world = loaded.world
        let robot = loaded.robot
        let articulation = robot.articulation

        let links = world.linkCount(articulation: articulation)
        var dofCount = 0
        var totalMass = 0.0
        var zeroMass: [String] = []
        var implausible: [ModelValidation.LinkMass] = []
        var unlimited: [String] = []
        var floatingBase = false

        // A robot link heavier than this is almost always a units mistake —
        // grams read as kilograms, or an inertia tensor pasted into a mass field.
        let implausiblyHeavy = 500.0
        // The URDF importer substitutes `defaultLinkMass` (1 g) for links that
        // declare no <inertial>, so this threshold catches exactly the links whose
        // inertia is a placeholder rather than measured.
        let implausiblyLight = 1e-3
        let effectivelyZero = 1e-9

        for link in 0..<links {
            let name = world.name(articulation: articulation, link: link)
            let kind = world.jointKind(articulation: articulation, link: link)
            let mass = world.mass(articulation: articulation, link: link)

            dofCount += kind.dofCount
            totalMass += mass
            if kind == .free { floatingBase = true }

            if kind != .fixed {
                // Massless *fixed* links are harmless — they are frames, and the
                // MJCF importer synthesises one itself as the world anchor. A
                // massless link on a movable joint is a singular mass matrix.
                if mass <= effectivelyZero {
                    zeroMass.append(name)
                } else if mass <= implausiblyLight || mass >= implausiblyHeavy {
                    implausible.append(ModelValidation.LinkMass(name: name, mass: mass))
                }
                if world.jointLimits(articulation: articulation, link: link) == nil {
                    unlimited.append(name)
                }
            }
        }

        let unresolved = loaded.unresolvedMeshes
        let actuators = robot.actuators.isEmpty ? world.actuatorCount : robot.actuators.count

        // Expected DOF: the registry counts joints, Kinetic counts the floating
        // base too, so add it back before comparing.
        let expectedDOF = entry.dof + (floatingBase ? 6 : 0)

        var warnings: [String] = []

        if !unresolved.isEmpty {
            let sample = unresolved.prefix(5).joined(separator: ", ")
            let more = unresolved.count > 5 ? " (+\(unresolved.count - 5) more)" : ""
            warnings.append("""
                \(unresolved.count) mesh reference(s) did not resolve and were replaced with \
                4 cm placeholder boxes: \(sample)\(more). Either the fetch is incomplete — \
                re-run fetch("\(entry.id)") — or the meshes are Collada/glTF, which \
                MeshLoader does not read.
                """)
        }
        if !zeroMass.isEmpty {
            warnings.append("""
                \(zeroMass.count) movable link(s) have no mass (\(zeroMass.prefix(4).joined(separator: ", "))). \
                The mass matrix is singular along their axes; the solver will produce \
                unbounded accelerations there.
                """)
        }
        if !implausible.isEmpty {
            let sample = implausible.prefix(3)
                .map { "\($0.name) \(format(kilograms: $0.mass))" }
                .joined(separator: ", ")
            warnings.append("""
                \(implausible.count) link(s) have implausible mass for robot hardware: \(sample). \
                Under 1 g usually means the description omitted <inertial> and the importer \
                substituted a placeholder; over 500 kg usually means a units error.
                """)
        }
        if totalMass <= effectivelyZero {
            warnings.append("""
                total mass is effectively zero, so gravity and contact response are \
                meaningless. The description almost certainly carries no inertial data.
                """)
        }
        if !unlimited.isEmpty {
            warnings.append("""
                \(unlimited.count) movable joint(s) have no position limits \
                (\(unlimited.prefix(4).joined(separator: ", "))). Correct for continuous \
                wrists and wheels; everywhere else it lets a controller wind the joint \
                past its physical stop.
                """)
        }
        if dofCount != expectedDOF {
            warnings.append("""
                imported \(dofCount) DOF but the registry records \(expectedDOF) \
                (\(entry.dof) joint DOF\(floatingBase ? " plus a 6-DOF floating base" : "")). \
                Upstream has changed since this entry was verified, or the importer dropped \
                a joint type it does not model.
                """)
        }
        if actuators == 0 {
            warnings.append("""
                no actuators were created, so this model can only be driven by writing \
                generalized forces directly. Check the description's <actuator> block.
                """)
        }
        if floatingBase != entry.floatingBase {
            warnings.append("""
                base is \(floatingBase ? "floating" : "fixed") but the registry records it as \
                \(entry.floatingBase ? "floating" : "fixed"). Joint indices will be offset by \
                6 relative to what a controller written against the registry expects.
                """)
        }
        if !entry.notes.isEmpty {
            // Not a defect, but the caveats are exactly what a validation report is
            // for, and they belong next to the numbers they explain.
            warnings.append("registry caveats for '\(entry.id)': \(oneLine(entry.notes))")
        }

        return ModelValidation(
            id: entry.id,
            displayName: entry.displayName,
            vendor: entry.vendor,
            format: entry.format,
            license: entry.licenseIdentifier,
            licenseURL: entry.licenseURL,
            sourceURL: entry.browseURL,
            linkCount: links,
            dofCount: dofCount,
            declaredDOF: entry.dof,
            actuatorCount: actuators,
            geomCount: world.geomCount,
            totalMass: totalMass,
            zeroMassLinks: zeroMass,
            implausibleMassLinks: implausible,
            unlimitedJoints: unlimited,
            unresolvedMeshes: unresolved,
            hasFloatingBase: floatingBase,
            warnings: warnings)
    }

    // MARK: - Loading internals

    private struct LoadResult {
        let world: World
        let robot: Robot
        let unresolvedMeshes: [String]
    }

    private func loadReportingWarnings(_ id: String, into world: World?) throws -> LoadResult {
        let entry = try requireEntry(id)
        let root = cacheURL(for: entry.id)
        let description = root.appendingPathComponent(entry.path)

        guard let size = try? fileSize(of: description), size > 0 else {
            throw ModelLibraryError.notCached(id: entry.id, expected: description)
        }

        let sink = WarningSink()
        let meshes = MeshLibrary(searchPaths: meshSearchPaths(for: entry, root: root))

        do {
            switch entry.format {
            case .urdf:
                var options = URDFImportOptions()
                options.meshLibrary = meshes
                options.packageRoots = meshes.searchPaths
                options.fixedBase = !entry.floatingBase
                options.onWarning = { [sink] message in sink.add(message) }
                let result = try URDF.load(contentsOf: description, into: world, options: options)
                return LoadResult(world: result.world, robot: result.robot,
                                  unresolvedMeshes: sink.unresolvedMeshURIs)

            case .mjcf:
                var options = MJCFImportOptions()
                options.meshLibrary = meshes
                options.onWarning = { [sink] message in sink.add(message) }
                let result = try MJCF.load(contentsOf: description, into: world, options: options)
                return LoadResult(world: result.world, robot: result.robot,
                                  unresolvedMeshes: sink.unresolvedMeshURIs)
            }
        } catch {
            throw ModelLibraryError.importFailed(id: entry.id, at: description,
                                                 underlying: String(describing: error))
        }
    }

    /// Directories the mesh loader searches, most specific first.
    ///
    /// Descriptions reference geometry three different ways and all three have to
    /// work against one downloaded tree:
    ///   * MJCF `<mesh file="link0.stl">` with `meshdir="assets"` → model/assets
    ///   * URDF `package://franka_description/meshes/x.obj` → the directory that
    ///     *contains* `franka_description`, wherever that sits in the repo
    ///   * URDF `kuka_allegro_description/meshes/x.obj`, a bare repo-relative path
    ///
    /// Walking from the description's own directory up to the cache root covers
    /// all three without the registry having to spell out a mesh root per entry.
    private func meshSearchPaths(for entry: ModelEntry, root: URL) -> [URL] {
        var paths: [URL] = []
        func add(_ url: URL) {
            let standard = url.standardizedFileURL
            guard !paths.contains(standard) else { return }
            paths.append(standard)
        }

        let descriptionDirectory = root.appendingPathComponent(entry.path)
            .deletingLastPathComponent()
        add(descriptionDirectory)
        add(descriptionDirectory.appendingPathComponent("assets", isDirectory: true))
        add(descriptionDirectory.appendingPathComponent("meshes", isDirectory: true))

        let rootPath = root.standardizedFileURL.path
        var current = descriptionDirectory.standardizedFileURL
        while current.path.count > rootPath.count, current.path.hasPrefix(rootPath) {
            current = current.deletingLastPathComponent().standardizedFileURL
            add(current)
            add(current.appendingPathComponent("assets", isDirectory: true))
            add(current.appendingPathComponent("meshes", isDirectory: true))
        }
        add(root)
        return paths
    }

    // MARK: - Fetch internals

    /// GitHub's recursive tree listing, decoded to the two fields we use.
    private struct TreeListing: Decodable {
        struct Node: Decodable {
            let path: String
            let type: String
            let size: Int?
        }
        let tree: [Node]
        /// GitHub caps the listing; a truncated tree cannot be trusted to contain
        /// every mesh, so the caller falls back to the archive.
        let truncated: Bool?
    }

    private struct SparseFetchError: Error, CustomStringConvertible {
        let description: String
    }

    /// Lists the repository once, then downloads only the blobs this model needs.
    private func sparseFetch(_ entry: ModelEntry, into staging: URL,
                             progress: ((Double) -> Void)?) async throws -> Int {
        let listingURL = entry.treeListingURL
        var request = URLRequest(url: listingURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // Anonymous callers get 60 requests an hour. Honouring a token when one is
        // present costs nothing and rescues users who fetch several models at once.
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelLibraryError.transport(id: entry.id, url: listingURL,
                                              status: http.statusCode)
        }

        let listing: TreeListing
        do {
            listing = try JSONDecoder().decode(TreeListing.self, from: data)
        } catch {
            throw SparseFetchError(description: "tree listing was not valid JSON")
        }
        if listing.truncated == true {
            throw SparseFetchError(description: "tree listing was truncated by GitHub")
        }

        // The licence always comes along: a cached model that cannot show its terms
        // is a licensing problem waiting to happen.
        var wanted = entry.subtrees
        if !wanted.contains(entry.licensePath) { wanted.append(entry.licensePath) }
        if !wanted.contains(entry.path) { wanted.append(entry.path) }

        let files = listing.tree.filter { node in
            node.type == "blob" && wanted.contains { matches(path: node.path, prefix: $0) }
        }
        guard !files.isEmpty else {
            throw ModelLibraryError.nothingToDownload(id: entry.id, subtrees: entry.subtrees)
        }

        try await download(paths: files.map(\.path), of: entry, into: staging, progress: progress)
        return files.count
    }

    /// Downloads blobs with bounded concurrency, reporting progress on this task.
    private func download(paths: [String], of entry: ModelEntry, into staging: URL,
                          progress: ((Double) -> Void)?) async throws {
        let total = paths.count
        var completed = 0

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0

            func enqueue() {
                guard next < total else { return }
                let path = paths[next]
                next += 1
                let source = entry.rawURL(path)
                let target = staging.appendingPathComponent(path)
                let session = self.session
                let fileManager = self.fileManager
                let id = entry.id
                group.addTask {
                    try Task.checkCancellation()
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
                    let (temporary, response) = try await session.download(from: source)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        try? fileManager.removeItem(at: temporary)
                        throw ModelLibraryError.transport(id: id, url: source,
                                                          status: http.statusCode)
                    }
                    // URLSession deletes the temporary file when this task returns,
                    // so the move has to happen here rather than later.
                    try? fileManager.removeItem(at: target)
                    try fileManager.moveItem(at: temporary, to: target)
                }
            }

            for _ in 0..<min(maxConcurrentDownloads, total) { enqueue() }

            // Progress is reported here, on the task that owns `progress`, rather
            // than inside the child tasks — no cross-task call, no data race.
            while try await group.next() != nil {
                completed += 1
                progress?(Double(completed) / Double(total))
                enqueue()
            }
        }
    }

    /// Downloads the repository tarball and extracts only the model's subtrees.
    ///
    /// Used when the tree listing is unavailable or truncated. Costs far more
    /// bandwidth than the sparse path, which is why it is the fallback.
    private func archiveFetch(_ entry: ModelEntry, into staging: URL,
                              progress: ((Double) -> Void)?) async throws -> Int {
        let archiveURL = entry.archiveURL
        let (temporary, response) = try await session.download(from: archiveURL)
        defer { try? fileManager.removeItem(at: temporary) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelLibraryError.transport(id: entry.id, url: archiveURL,
                                              status: http.statusCode)
        }
        progress?(0.5)

        // GitHub tarballs wrap everything in a `<repo>-<ref>/` directory, so one
        // strip level lands the archive at the repository root.
        var arguments = ["-xzf", temporary.path, "-C", staging.path, "--strip-components", "1"]
        var wanted = entry.subtrees
        if !wanted.contains(entry.licensePath) { wanted.append(entry.licensePath) }
        if !wanted.contains(entry.path) { wanted.append(entry.path) }
        // bsdtar treats trailing operands as member patterns; matching both the
        // exact path and everything beneath it covers files and directories.
        for prefix in wanted {
            arguments.append("*/\(prefix)")
            arguments.append("*/\(prefix)/*")
        }

        try await runTar(arguments: arguments, id: entry.id)
        progress?(0.9)
        return countFiles(in: staging)
    }

    /// Runs `tar` without blocking a thread: the continuation resumes from the
    /// process's termination handler.
    ///
    /// Diagnostics go to a temporary file rather than a `Pipe`. A pipe nobody
    /// drains deadlocks once its buffer fills, and a file handle avoids capturing
    /// non-Sendable state in the termination handler.
    private func runTar(arguments: [String], id: String) async throws {
        let diagnostics = fileManager.temporaryDirectory
            .appendingPathComponent("kinetic-tar-\(UUID().uuidString).log")
        fileManager.createFile(atPath: diagnostics.path, contents: nil)
        defer { try? fileManager.removeItem(at: diagnostics) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        if let handle = try? FileHandle(forWritingTo: diagnostics) {
            process.standardError = handle
        } else {
            process.standardError = FileHandle.nullDevice
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ModelLibraryError.archiveExtractionFailed(
                    id: id, status: -1, detail: String(describing: error)))
            }
        }

        guard status != 0 else { return }
        let detail = String(decoding: (try? Data(contentsOf: diagnostics)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ModelLibraryError.archiveExtractionFailed(
            id: id, status: status,
            detail: detail.isEmpty ? "no diagnostic output" : detail)
    }

    /// Confirms the download actually contains the description the registry named,
    /// and that it is the format the registry claims.
    ///
    /// Without this a 404 page, a rate-limit body or a moved directory would be
    /// promoted into the cache and only fail much later, at load time.
    private func verifyDescription(for entry: ModelEntry, in staging: URL,
                                   downloadedFiles: Int) throws {
        let description = staging.appendingPathComponent(entry.path)
        guard let size = try? fileSize(of: description), size > 0 else {
            throw ModelLibraryError.descriptionMissing(id: entry.id, expected: description,
                                                       downloadedFiles: downloadedFiles)
        }
        guard let data = try? Data(contentsOf: description) else {
            throw ModelLibraryError.descriptionMalformed(id: entry.id, at: description,
                                                         detail: "file is unreadable")
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw ModelLibraryError.descriptionMalformed(
                id: entry.id, at: description,
                detail: "not well-formed XML (\(String(describing: error)))")
        }
        let expected = entry.format.rootElementName
        guard let root = document.rootElement(), root.name == expected else {
            let found = document.rootElement()?.name ?? "no root element"
            throw ModelLibraryError.descriptionMalformed(
                id: entry.id, at: description,
                detail: "expected a <\(expected)> root for \(entry.format.displayName), found \(found)")
        }
    }

    // MARK: - Filesystem helpers

    private func requireEntry(_ id: String) throws -> ModelEntry {
        if let entry = ModelRegistry.entry(id: id) { return entry }
        let suggestions = ModelRegistry.search(id).prefix(3).map(\.id)
        throw ModelLibraryError.unknownModel(id: id, suggestions: Array(suggestions))
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ModelLibraryError.cacheUnavailable(path: url.path,
                                                     underlying: String(describing: error))
        }
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            total += (try? fileSize(of: child)) ?? 0
        }
        return total
    }

    private func countFiles(in url: URL) -> Int {
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        var count = 0
        for case let child as URL in walker {
            if (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    /// Registry ids are already `[a-z0-9-]`, but the cache path is built from
    /// caller-supplied text, so anything that could escape the cache directory is
    /// stripped rather than trusted.
    private func sanitised(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = id.lowercased().filter { allowed.contains($0) }
        return cleaned.replacingOccurrences(of: "..", with: "-")
    }

    private func matches(path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private func format(kilograms: Double) -> String {
        kilograms < 0.01
            ? String(format: "%.4g g", kilograms * 1000)
            : String(format: "%.4g kg", kilograms)
    }

    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }
}

// MARK: - Warning collection

/// Importer warnings arrive on whatever thread decoded the mesh, so collection is
/// lock-guarded rather than relying on the caller's isolation.
private final class WarningSink: @unchecked Sendable {
    private var messages: [String] = []
    private let lock = NSLock()

    func add(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    /// Both importers phrase the failure as `could not resolve mesh 'uri' ...`, so
    /// the quoted URI is the actionable part; the rest is prose.
    var unresolvedMeshURIs: [String] {
        all.compactMap { message in
            guard let open = message.firstIndex(of: "'") else { return message }
            let rest = message.index(after: open)
            guard let close = message[rest...].firstIndex(of: "'") else { return message }
            return String(message[rest..<close])
        }
    }
}

// MARK: - Repository URLs used only by the fetcher

extension ModelEntry {
    /// GitHub's recursive tree listing for this entry's repository and reference.
    var treeListingURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repositoryName)"
            + "/git/trees/\(reference)?recursive=1")
            ?? repositoryURL
    }

    /// Gzipped tarball of the repository at this entry's reference.
    var archiveURL: URL {
        URL(string: "https://codeload.github.com/\(owner)/\(repositoryName)"
            + "/tar.gz/\(reference)")
            ?? repositoryURL
    }
}
