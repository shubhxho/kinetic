//
//  ModelRegistry.swift
//  Kinetic
//
//  A curated catalogue of publicly available robot descriptions.
//
//  Nothing here is vendored. Every entry is a pointer at somebody else's
//  repository: owner, branch, path, licence. `ModelLibrary` turns a pointer into
//  a local cache; this file only says where to look and what you are agreeing to
//  when you look there.
//
//  Every path in this file was verified against the live repository at the
//  `reference` recorded on the entry. Entries that could not be verified were
//  dropped rather than guessed — a catalogue that 404s is worse than a short one.
//
//  Two importer limitations shape the `notes` below, so they are stated once here
//  rather than repeated on all fourteen entries:
//
//  1. `MJCF.swift` does not read `<equality>` or `<tendon>`. Models that close a
//     linkage with an equality constraint or couple joints through a tendon import
//     as an open chain: the joints exist and move, but they move independently.
//  2. `MeshLoader.swift` reads STL, OBJ and ASCII PLY. Collada (`.dae`) and glTF
//     are rejected, so a description whose visual geometry is Collada renders from
//     its collision meshes.
//

import Foundation

/// The description dialect a model is authored in.
public enum ModelFormat: String, Sendable, CaseIterable {
    case urdf
    case mjcf

    /// File extension conventionally used by the format.
    public var fileExtension: String {
        switch self {
        case .urdf: return "urdf"
        case .mjcf: return "xml"
        }
    }

    /// Root XML element a well-formed description of this format must have.
    /// `ModelLibrary` checks this after a download so a redirect page or an error
    /// body cannot masquerade as a robot.
    public var rootElementName: String {
        switch self {
        case .urdf: return "robot"
        case .mjcf: return "mujoco"
        }
    }

    public var displayName: String {
        switch self {
        case .urdf: return "URDF"
        case .mjcf: return "MJCF"
        }
    }
}

/// One robot description, addressed by repository rather than copied into Kinetic.
public struct ModelEntry: Sendable, Hashable, Identifiable {
    /// Stable, lowercase, hyphenated handle. This is what a user types.
    public let id: String
    public let displayName: String
    /// Who built the hardware, not who published the file.
    public let vendor: String
    /// One line, for a list row.
    public let summary: String
    public let format: ModelFormat

    /// GitHub owner and repository holding the description.
    public let owner: String
    public let repositoryName: String
    /// Branch, tag or commit the paths below were verified against. Recorded
    /// explicitly so a future upstream reshuffle is visible as a fetch failure
    /// rather than as a silently different robot.
    public let reference: String
    /// Repository-relative path of the description file.
    public let path: String
    /// Repository-relative prefixes that must be downloaded for the description to
    /// load: the description itself plus the meshes it references. Kept narrow so a
    /// fetch pulls kilobytes of geometry instead of a whole repository.
    public let subtrees: [String]

    /// SPDX identifier of the licence that governs *this model's* files. Menagerie
    /// ships a separate licence per model directory, so this is rarely the
    /// repository's own licence.
    public let licenseIdentifier: String
    /// Repository-relative path of the licence text, so the exact terms can be
    /// shown rather than paraphrased.
    public let licensePath: String

    /// Movable joint degrees of freedom, excluding a floating base.
    public let dof: Int
    /// Actuators the description declares. For URDF this is the count Kinetic
    /// synthesises — one position actuator per movable joint — because URDF has no
    /// actuator concept of its own.
    public let actuators: Int
    /// True when the description's root body is free rather than bolted down.
    public let floatingBase: Bool

    /// Extra search terms that are not already in the name, vendor or summary.
    public let tags: [String]
    /// Real caveats: what will look wrong, what is missing, what to distrust.
    public let notes: String

    public init(id: String, displayName: String, vendor: String, summary: String,
                format: ModelFormat, owner: String, repositoryName: String, reference: String,
                path: String, subtrees: [String], licenseIdentifier: String, licensePath: String,
                dof: Int, actuators: Int, floatingBase: Bool, tags: [String], notes: String) {
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.summary = summary
        self.format = format
        self.owner = owner
        self.repositoryName = repositoryName
        self.reference = reference
        self.path = path
        self.subtrees = subtrees
        self.licenseIdentifier = licenseIdentifier
        self.licensePath = licensePath
        self.dof = dof
        self.actuators = actuators
        self.floatingBase = floatingBase
        self.tags = tags
        self.notes = notes
    }

    /// `https://github.com/<owner>/<repo>`
    public var repositoryURL: URL { ModelEntry.https("github.com/\(owner)/\(repositoryName)") }

    /// Human-browsable page for the description file.
    public var browseURL: URL {
        ModelEntry.https("github.com/\(owner)/\(repositoryName)/blob/\(reference)/\(path)")
    }

    /// Raw bytes of the description file.
    public var descriptionURL: URL { rawURL(path) }

    /// Raw bytes of the licence that governs this model.
    public var licenseURL: URL { rawURL(licensePath) }

    /// Raw content URL for any repository-relative path in this entry's repository.
    public func rawURL(_ repositoryRelativePath: String) -> URL {
        let escaped = repositoryRelativePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryRelativePath
        return ModelEntry.https(
            "raw.githubusercontent.com/\(owner)/\(repositoryName)/\(reference)/\(escaped)")
    }

    /// File name of the description, useful for cache layout and error text.
    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Builds an https URL from an ASCII literal assembled above.
    ///
    /// `URL(string:)` is optional and force unwrapping is banned, so a malformed
    /// literal degrades to an unroutable file URL. Every caller either fetches
    /// (and gets a clear network error) or displays (and shows an obviously wrong
    /// link), which surfaces the typo without taking the process down.
    private static func https(_ hostAndPath: String) -> URL {
        URL(string: "https://" + hostAndPath)
            ?? URL(fileURLWithPath: "/invalid-model-registry-url/" + hostAndPath)
    }
}

/// The catalogue itself.
public enum ModelRegistry {

    // MARK: Shared repository coordinates

    private static let menagerieOwner = "google-deepmind"
    private static let menagerieRepo = "mujoco_menagerie"
    /// Menagerie has no release tags; `main` is what everyone consumes.
    private static let menagerieRef = "main"

    /// NVIDIA's Isaac Gym environments repository. Archived upstream, which makes
    /// it a *stable* pin rather than a dead one: the paths cannot drift.
    private static let nvidiaOwner = "isaac-sim"
    private static let nvidiaRepo = "IsaacGymEnvs"
    private static let nvidiaRef = "main"

    /// Menagerie lays every model out the same way: `<dir>/<model>.xml` beside a
    /// `<dir>/assets/` folder of meshes, with a per-model `LICENSE`. Fetching the
    /// whole model directory is both the smallest correct unit and the one that
    /// carries the licence text along with the geometry.
    private static func menagerie(id: String, displayName: String, vendor: String,
                                  summary: String, directory: String, file: String,
                                  license: String, dof: Int, actuators: Int,
                                  floatingBase: Bool, tags: [String], notes: String) -> ModelEntry {
        ModelEntry(
            id: id, displayName: displayName, vendor: vendor, summary: summary, format: .mjcf,
            owner: menagerieOwner, repositoryName: menagerieRepo, reference: menagerieRef,
            path: "\(directory)/\(file)",
            subtrees: [directory],
            licenseIdentifier: license, licensePath: "\(directory)/LICENSE",
            dof: dof, actuators: actuators, floatingBase: floatingBase,
            tags: tags + ["mujoco", "menagerie"], notes: notes)
    }

    // MARK: The catalogue

    public static let all: [ModelEntry] = [

        // MARK: Arms

        menagerie(
            id: "franka-panda",
            displayName: "Franka Emika Panda",
            vendor: "Franka Emika",
            summary: "Seven-axis collaborative arm with the two-finger Franka Hand attached.",
            directory: "franka_emika_panda", file: "panda.xml",
            license: "Apache-2.0",
            dof: 9, actuators: 8, floatingBase: false,
            tags: ["arm", "manipulator", "gripper", "panda", "fr3", "cobot"],
            notes: """
                Nine joints: seven arm revolutes plus two prismatic finger slides. \
                Only eight actuators, because the two fingers are driven through one \
                tendon and held together by an equality constraint — Kinetic reads \
                neither, so the fingers import as two independent slides and the \
                gripper must be commanded on both. Arm links carry real inertials. \
                The same platform is Isaac Lab's `Robots/FrankaEmika/panda_instanceable.usd`; \
                that asset is USD and is not interchangeable with this file. \
                Use `nvidia-franka-panda-urdf` for the URDF flavour.
                """),

        menagerie(
            id: "franka-fr3",
            displayName: "Franka Research 3",
            vendor: "Franka Robotics",
            summary: "Successor to the Panda: same seven-axis kinematics, updated dynamics, no hand.",
            directory: "franka_fr3", file: "fr3.xml",
            license: "Apache-2.0",
            dof: 7, actuators: 7, floatingBase: false,
            tags: ["arm", "manipulator", "research", "cobot"],
            notes: """
                Arm only — `fr3.xml` ships no end effector, so a grasping task needs a \
                gripper welded on (`robotiq-2f85` is the usual companion). No equality \
                or tendon constructs, so this imports more faithfully than `franka-panda`.
                """),

        menagerie(
            id: "ur5e",
            displayName: "Universal Robots UR5e",
            vendor: "Universal Robots",
            summary: "Six-axis 5 kg-payload collaborative arm, the default lab manipulator.",
            directory: "universal_robots_ur5e", file: "ur5e.xml",
            license: "BSD-3-Clause",
            dof: 6, actuators: 6, floatingBase: false,
            tags: ["arm", "manipulator", "cobot", "ur", "e-series"],
            notes: """
                Clean six-revolute chain, no closed loops, no tendons — one of the most \
                faithful imports in the catalogue. Wrist joints are unlimited in the \
                source (continuous rotation), so `validate` reports three joints without \
                limits; that is the real robot, not a defect. Ships no end effector. \
                Isaac Lab's `universal_robots.py` covers UR10/UR10e but not the UR5e, so \
                there is no direct Isaac counterpart for this one.
                """),

        menagerie(
            id: "ur10e",
            displayName: "Universal Robots UR10e",
            vendor: "Universal Robots",
            summary: "Six-axis 12.5 kg-payload arm with a 1300 mm reach — the UR5e's bigger sibling.",
            directory: "universal_robots_ur10e", file: "ur10e.xml",
            license: "BSD-3-Clause",
            dof: 6, actuators: 6, floatingBase: false,
            tags: ["arm", "manipulator", "cobot", "ur", "e-series"],
            notes: """
                Identical topology to `ur5e` with longer links and heavier inertials; \
                anything tuned on the UR5e transfers with re-tuned gains, not unchanged \
                ones. Isaac Lab ships the matching USD as \
                `Robots/UniversalRobots/ur10e/ur10e.usd`, which is USD, not MJCF.
                """),

        // MARK: Hands and grippers

        menagerie(
            id: "robotiq-2f85",
            displayName: "Robotiq 2F-85",
            vendor: "Robotiq",
            summary: "Adaptive parallel two-finger gripper, 85 mm stroke, one commanded axis.",
            directory: "robotiq_2f85", file: "2f85.xml",
            license: "BSD-2-Clause",
            dof: 8, actuators: 1, floatingBase: false,
            tags: ["gripper", "end-effector", "parallel-jaw", "adaptive"],
            notes: """
                The eight hinges form two four-bar linkages that the source closes with \
                three `<equality>` constraints and a tendon. Kinetic reads neither, so \
                this imports as eight *free-swinging* hinges and the fingers will flop \
                instead of tracking the drive joint. Usable as visual geometry and as a \
                kinematic reference; not trustworthy for grasp-force simulation until \
                equality constraints land in the MJCF importer. Licence is BSD-2-Clause \
                (ROS-Industrial, 2013) — two clauses, not three. No Isaac Lab asset config \
                ships for this gripper.
                """),

        menagerie(
            id: "shadow-hand",
            displayName: "Shadow Dexterous Hand (right)",
            vendor: "Shadow Robot Company",
            summary: "Anthropomorphic 24-joint right hand on a forearm mount — the dexterity benchmark.",
            directory: "shadow_hand", file: "right_hand.xml",
            license: "Apache-2.0",
            dof: 24, actuators: 20, floatingBase: false,
            tags: ["hand", "dexterous", "manipulation", "shadow", "five-finger"],
            notes: """
                Twenty-four joints, twenty actuators: the four distal finger joints are \
                coupled to their middle joints through tendons, which Kinetic does not \
                import, so those four move independently here. Fetch also brings \
                `left_hand.xml` and `keyframes.xml` from the same directory. Isaac Lab \
                ships the platform as `Robots/ShadowRobot/ShadowHand/shadow_hand_instanceable.usd` \
                — USD, not MJCF.
                """),

        // MARK: Quadrupeds

        menagerie(
            id: "unitree-go1",
            displayName: "Unitree Go1",
            vendor: "Unitree Robotics",
            summary: "12 kg twelve-actuator quadruped — the cheap, ubiquitous locomotion testbed.",
            directory: "unitree_go1", file: "go1.xml",
            license: "BSD-3-Clause",
            dof: 12, actuators: 12, floatingBase: true,
            tags: ["quadruped", "legged", "locomotion", "dog"],
            notes: """
                Floating base, so the world state carries six extra base DOF ahead of the \
                twelve joints; a controller indexing joints from zero will be off by six. \
                Geometry is five STL meshes reused across the four legs. Isaac Lab ships \
                the matching `Robots/Unitree/Go1/go1.usd`.
                """),

        menagerie(
            id: "unitree-go2",
            displayName: "Unitree Go2",
            vendor: "Unitree Robotics",
            summary: "Successor to the Go1: same twelve-DOF layout, better meshes and inertials.",
            directory: "unitree_go2", file: "go2.xml",
            license: "BSD-3-Clause",
            dof: 12, actuators: 12, floatingBase: true,
            tags: ["quadruped", "legged", "locomotion", "dog"],
            notes: """
                Prefer this over `unitree-go1` for new work — the visual meshes are split \
                OBJ with per-part materials and the inertials are measured rather than \
                estimated. The directory also holds `go2_mjx.xml`, a variant simplified \
                for MuJoCo-MJX batch training; `go2.xml` is the full-fidelity one. \
                Isaac Lab ships `Robots/Unitree/Go2/go2.usd`.
                """),

        menagerie(
            id: "anymal-c",
            displayName: "ANYbotics ANYmal C",
            vendor: "ANYbotics",
            summary: "50 kg industrial inspection quadruped with series-elastic actuators.",
            directory: "anybotics_anymal_c", file: "anymal_c.xml",
            license: "BSD-3-Clause",
            dof: 12, actuators: 12, floatingBase: true,
            tags: ["quadruped", "legged", "locomotion", "inspection", "anymal"],
            notes: """
                Roughly four times the Go2's mass, so contact and solver settings tuned on \
                a small quadruped will not transfer. The real actuators are series-elastic \
                and the MJCF models them as plain position-controlled joints — torque \
                traces from this model are optimistic. Isaac Lab ships \
                `Robots/ANYbotics/ANYmal-C/anymal_c.usd`; note NVIDIA also publishes an \
                ANYmal C URDF in `isaac-sim/IsaacGymEnvs`, but every one of its 45 meshes \
                is Collada, which Kinetic cannot read, so this MJCF is the usable route.
                """),

        // MARK: Humanoids

        menagerie(
            id: "unitree-h1",
            displayName: "Unitree H1",
            vendor: "Unitree Robotics",
            summary: "47 kg full-size humanoid, nineteen actuated joints, floating base.",
            directory: "unitree_h1", file: "h1.xml",
            license: "BSD-3-Clause",
            dof: 19, actuators: 19, floatingBase: true,
            tags: ["humanoid", "biped", "legged", "locomotion", "whole-body"],
            notes: """
                Nineteen joints plus a six-DOF floating base. Hands are stubs — no fingers, \
                so this is a locomotion and whole-body-control model, not a manipulation \
                one. Tall and top-heavy: it will fall over immediately without a balancing \
                controller, which is expected rather than an import fault. Isaac Lab ships \
                `Robots/Unitree/H1/h1.usd`.
                """),

        menagerie(
            id: "unitree-g1",
            displayName: "Unitree G1",
            vendor: "Unitree Robotics",
            summary: "35 kg compact humanoid with 29 actuated joints including three-DOF wrists.",
            directory: "unitree_g1", file: "g1.xml",
            license: "BSD-3-Clause",
            dof: 29, actuators: 29, floatingBase: true,
            tags: ["humanoid", "biped", "legged", "locomotion", "whole-body"],
            notes: """
                The widest joint count in this catalogue and correspondingly the slowest to \
                step. Meshes are `.STL` with an uppercase extension — harmless here because \
                the mesh loader lowercases before dispatching, but it breaks case-sensitive \
                tooling elsewhere. Isaac Lab ships `Robots/Unitree/G1/g1.usd`.
                """),

        // MARK: NVIDIA-published URDF

        ModelEntry(
            id: "nvidia-franka-panda-urdf",
            displayName: "Franka Panda (NVIDIA URDF)",
            vendor: "NVIDIA",
            summary: "NVIDIA's URDF packaging of the Panda, as shipped with Isaac Gym Envs.",
            format: .urdf,
            owner: nvidiaOwner, repositoryName: nvidiaRepo, reference: nvidiaRef,
            path: "assets/urdf/franka_description/robots/franka_panda.urdf",
            // Visual geometry in this package is Collada, which the mesh loader
            // rejects, so fetching it would cost 19 MB and buy nothing. The
            // collision OBJs are 286 KB and are what actually loads.
            subtrees: [
                "assets/urdf/franka_description/robots",
                "assets/urdf/franka_description/meshes/collision",
                "assets/licenses/franka-LICENSE.txt",
            ],
            licenseIdentifier: "Apache-2.0",
            licensePath: "assets/licenses/franka-LICENSE.txt",
            dof: 9, actuators: 9, floatingBase: false,
            tags: ["arm", "manipulator", "gripper", "panda", "nvidia", "isaac", "urdf"],
            notes: """
                Seven revolute arm joints plus two prismatic fingers, no gripper coupling \
                declared — URDF cannot express one, so the fingers are genuinely \
                independent here rather than importing that way by accident. Visual meshes \
                are Collada (`.dae`) which Kinetic does not read, so only the collision \
                OBJs are fetched and the robot renders from its collision hulls: correct \
                shape, blockier silhouette. The repository is BSD-3-Clause but this asset \
                carries its own Apache-2.0 notice in `assets/licenses/franka-LICENSE.txt`, \
                which is the licence recorded here. The repository is archived upstream, \
                which makes the pin stable. NVIDIA's own Isaac Sim robot assets are USD, \
                not URDF — the Panda there is `Robots/FrankaEmika/panda_instanceable.usd` \
                on the Isaac Nucleus server and is not downloadable as a description file.
                """),

        ModelEntry(
            id: "nvidia-allegro-hand",
            displayName: "Allegro Hand (NVIDIA URDF)",
            vendor: "Wonik Robotics",
            summary: "Sixteen-DOF four-finger research hand with touch-sensor frames.",
            format: .urdf,
            owner: nvidiaOwner, repositoryName: nvidiaRepo, reference: nvidiaRef,
            path: "assets/urdf/kuka_allegro_description/allegro_touch_sensor.urdf",
            // The three mesh directories this URDF actually references — hand,
            // wrist mount, fingertip sensors — for 1.8 MB. The sibling `iiwa7`
            // set in the same folder is 46 MB and belongs to the entry below.
            subtrees: [
                "assets/urdf/kuka_allegro_description/allegro_touch_sensor.urdf",
                "assets/urdf/kuka_allegro_description/meshes/allegro",
                "assets/urdf/kuka_allegro_description/meshes/mounts",
                "assets/urdf/kuka_allegro_description/meshes/touchsensor",
            ],
            licenseIdentifier: "BSD-3-Clause",
            licensePath: "LICENSE.txt",
            dof: 16, actuators: 16, floatingBase: false,
            tags: ["hand", "dexterous", "manipulation", "allegro", "nvidia", "isaac", "urdf"],
            notes: """
                All sixteen mesh files are OBJ, so this loads with full geometry — the most \
                faithful URDF import in the catalogue. Four fingers, four joints each; the \
                "touch sensor" in the file name is a set of extra fixed frames, not a \
                simulated sensor, and Kinetic imports them as massless fixed links (expect \
                five of those in `validate`). The hand has no wrist: it imports with a fixed \
                base at `base_link`, so mount it or weld it to an arm. Licence is the \
                repository's BSD-3-Clause; there is no separate per-asset notice for this one. \
                Isaac Sim ships the same hand as `Robots/WonikRobotics/AllegroHand/allegro_hand_instanceable.usd`, \
                which is USD and not a substitute for this URDF.
                """),

        ModelEntry(
            id: "nvidia-kuka-allegro",
            displayName: "KUKA iiwa7 + Allegro Hand (NVIDIA URDF)",
            vendor: "NVIDIA",
            summary: "Seven-axis iiwa7 arm with the Allegro hand mounted — 23 DOF of dexterous reach.",
            format: .urdf,
            owner: nvidiaOwner, repositoryName: nvidiaRepo, reference: nvidiaRef,
            path: "assets/urdf/kuka_allegro_description/kuka_allegro_touch_sensor.urdf",
            subtrees: [
                "assets/urdf/kuka_allegro_description/kuka_allegro_touch_sensor.urdf",
                "assets/urdf/kuka_allegro_description/meshes",
                "assets/licenses/kukaiiwa-LICENSE.txt",
            ],
            licenseIdentifier: "BSD-3-Clause",
            licensePath: "assets/licenses/kukaiiwa-LICENSE.txt",
            dof: 23, actuators: 23, floatingBase: false,
            tags: ["arm", "hand", "dexterous", "manipulation", "kuka", "iiwa",
                   "allegro", "nvidia", "isaac", "urdf"],
            notes: """
                Twenty-three revolutes: seven iiwa7 arm joints and sixteen hand joints in one \
                tree, which is what makes it worth having over mounting the hand yourself. \
                The download is about 48 MB — the iiwa7 visual meshes are high-resolution OBJ \
                — so this is the one entry where the fetch is slow. All meshes are OBJ and load. \
                The arm asset carries its own notice in `assets/licenses/kukaiiwa-LICENSE.txt`; \
                the hand portion is covered by the repository's BSD-3-Clause `LICENSE.txt`.
                """),
    ]

    // MARK: Lookup

    /// Exact lookup by id. Case- and whitespace-insensitive because the id is
    /// something a human types on a command line.
    public static func entry(id: String) -> ModelEntry? {
        let key = normalise(id)
        return all.first { $0.id == key }
    }

    /// Ranked substring search across id, name, vendor, summary and tags.
    ///
    /// An empty query returns the whole catalogue, which is what a list command
    /// wants. Results are ordered by how specifically they matched — an id hit
    /// beats a name hit beats a description hit — so `search("panda")` puts the
    /// Panda first rather than every arm that mentions it in its notes.
    public static func search(_ query: String) -> [ModelEntry] {
        let needle = normalise(query)
        guard !needle.isEmpty else { return all }

        // Multi-word queries must match every word somewhere in the entry, so
        // "unitree humanoid" narrows instead of widening.
        let words = needle.split(separator: " ").map(String.init)

        var scored: [(entry: ModelEntry, score: Int, order: Int)] = []
        for (index, entry) in all.enumerated() {
            var total = 0
            var matchedAll = true
            for word in words {
                let score = relevance(of: entry, to: word)
                if score == 0 {
                    matchedAll = false
                    break
                }
                total += score
            }
            if matchedAll { scored.append((entry, total, index)) }
        }
        // Ties fall back to catalogue order, which is grouped by robot family.
        return scored
            .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
            .map(\.entry)
    }

    /// Catalogue grouped by hardware vendor, for a sectioned picker.
    public static var byVendor: [String: [ModelEntry]] {
        Dictionary(grouping: all, by: \.vendor)
            .mapValues { $0.sorted { $0.displayName < $1.displayName } }
    }

    /// Vendor names in display order, so a UI can iterate `byVendor` deterministically.
    public static var vendors: [String] {
        Array(Set(all.map(\.vendor))).sorted()
    }

    /// Every id in the catalogue, for shell completion and error suggestions.
    public static var identifiers: [String] { all.map(\.id) }

    // MARK: Scoring

    private static func relevance(of entry: ModelEntry, to word: String) -> Int {
        if entry.id == word { return 100 }
        if entry.id.contains(word) { return 50 }
        if normalise(entry.displayName).contains(word) { return 30 }
        if entry.tags.contains(where: { $0.contains(word) }) { return 20 }
        if normalise(entry.vendor).contains(word) { return 15 }
        if normalise(entry.summary).contains(word) { return 8 }
        if entry.format.rawValue == word { return 5 }
        if normalise(entry.notes).contains(word) { return 2 }
        return 0
    }

    private static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
