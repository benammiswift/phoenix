import Foundation

@MainActor
class GameViewModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var selectedGame: UUID
    @Published var selectedGameName: String
    var supabaseViewModel = SupabaseViewModel()
    
    init() {
        // Initialize selectedGame and selectedGameName
        selectedGame = Defaults[.selectedGame]
        selectedGameName = ""
        
        // Load games and assign the value to the optional variable
        games = loadGames().sorted()
        
        // Update selectedGameName using the loaded games
        if let game = getGameFromID(id: Defaults[.selectedGame]) {
            selectedGameName = game.name
        }
    }
    
    func getGameFromName(name: String) -> Game? {
        return games.first { $0.name == name }
    }

    func getGameFromID(id: UUID) -> Game? {
        return games.first { $0.id == id }
    }

    func addGame(_ game: Game) {
        logger.write("Adding game \(game.name).")
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx] = game
        } else {
            games.append(game)
        }
        saveGames()
    }
    
    func addGames(_ addedGames: [Game]) {
        for game in addedGames {
            logger.write("Adding game \(game.name).")
            if let idx = games.firstIndex(where: { $0.id == game.id }) {
                games[idx] = game
            } else {
                games.append(game)
            }
        }
        saveGames()
    }
    
    func toggleFavoriteFromID(_ id: UUID) {
        if let idx = games.firstIndex(where: { $0.id == id }) {
            games[idx].isFavorite.toggle()
        }
        saveGames()
    }
    
    func toggleHiddenFromID(_ id: UUID) {
        if let idx = games.firstIndex(where: { $0.id == id }) {
            games[idx].isHidden.toggle()
        }
        saveGames()
    }
    
    func deleteGameFromID(_ id: UUID) {
        if let idx = games.firstIndex(where: { $0.id == id }) {
            games.remove(at: idx)
        }
        saveGames()
    }

    func saveGames() {
        print("Saving games")
        games = games.sorted()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let gamesJSON = try JSONEncoder().encode(games)
            
            if var gamesJSONString = String(data: gamesJSON, encoding: .utf8) {
                // Add the necessary JSON elements for the string to be recognized as type "Games" on next read
                gamesJSONString = "{\"games\": \(gamesJSONString)}"
                writeGamesToJSON(data: gamesJSONString)
            }
        } catch {
            logger.write(error.localizedDescription)
        }
    }
    
    /// If varying game detection settings are enabled, run methods to check for those games
    /// Save the games once the check is done, then parse the saved JSON to get a list of games
    func loadGames() -> [Game] {
        Task {
            var steamGameNames: Set<String> = []
            var crossoverGameNames: Set<String> = []
            
            if Defaults[.steamDetection] {
                steamGameNames = await detectSteamGames()
            }
            
            if Defaults[.crossOverDetection] {
                crossoverGameNames = await detectCrossoverGames()
            }
            
            await compareSteamAndCrossoverGames(steamGameNames: steamGameNames, crossoverGameNames: crossoverGameNames)
        }
        
        let res = loadGamesFromJSON()
        return res.games
    }
    
    /// Detects Steam games from application support directory
    /// using the appmanifest_<steamID>.acf files and writes them to the games.json file.
    ///
    ///   - Parameters: None.
    ///
    ///   - Returns: Void.
    ///
    ///   - Throws: An error if there was a problem writing to the file.
    func detectSteamGames() async -> Set<String> {
        let fileManager = FileManager.default

        /// Get ~/Library/Application Support/Steam/steamapps by default.
        /// Or when App Sandbox is enabled ~/Library/Containers/com.<username>.Phoenix/Data/Library/Application Support/Steam/steamapps
        /// The user may also set a custom directory of their choice, so we get that directory if they have.

        let steamAppsDirectory = Defaults[.steamFolder]
        var steamGameNames: Set<String> = []
        
        // Find the appmanifest_<steamID>.acf files and parse data from them
        do {
            let steamAppsFiles = try fileManager.contentsOfDirectory(
                at: steamAppsDirectory, includingPropertiesForKeys: nil
            )
            for steamAppsFile in steamAppsFiles {
                let fileName = steamAppsFile.lastPathComponent
                if fileName.hasSuffix(".acf") {
                    let manifestFilePath = steamAppsFile
                    let manifestFileData = try Data(contentsOf: manifestFilePath)
                    let manifestDictionary = parseACFFile(data: manifestFileData)
                    let name = manifestDictionary["name"]
                    if let name = name {
                        steamGameNames.insert(name)
                        logger.write("\(name) detected in Steam directory.")
                    }
                }
            }
        } catch {
            logger.write("[ERROR]: Error adding to Steam games.")
        }
        return steamGameNames
    }

    /// Detects Crossover games from the user Applications directory
    /// And writes them to the games.json file
    ///
    ///    - Parameters: None
    ///
    ///    - Returns: Void
    func detectCrossoverGames() async -> Set<String> {
        let fileManager = FileManager.default
        
        /// Get ~/Applications/CrossOver by default.
        /// Or when App Sandbox is enabled ~/Library/Containers/com.<username>.Phoenix/Data/Applications/CrossOver
        /// The user may also set a custom directory of their choice, so we get that directory if they have.
        
        let crossoverDirectory = Defaults[.crossOverFolder]
        var crossoverGameNames: Set<String> = []
        
        // Find the <name>.app files and get name from them
        if let enumerator = fileManager.enumerator(at: crossoverDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator {
                let fileName = fileURL.lastPathComponent
                if fileName.hasSuffix(".app") {
                    let name = String(fileName.dropLast(4))
                    crossoverGameNames.insert(name)
                    logger.write("\(name) detected in CrossOver directory.")
                }
            }
        }
        return crossoverGameNames
    }

    func compareSteamAndCrossoverGames(steamGameNames: Set<String>, crossoverGameNames: Set<String>) async {
        let gameNames = Set(loadGamesFromJSON().games.map { $0.name })
        
        var steamGameNames = steamGameNames.subtracting(crossoverGameNames)
        var crossoverGameNames = crossoverGameNames
        
        steamGameNames.subtract(gameNames)
        crossoverGameNames.subtract(gameNames)
        
        var newGames: [Game] = []
        
        for steamName in steamGameNames {
            newGames.append(await saveSupabaseGameFromName(steamName, platform: Platform.steam, launcher: "open steam: //run/%@"))
        }
        for crossoverName in crossoverGameNames {
            newGames.append(await saveSupabaseGameFromName(crossoverName, platform: Platform.pc, launcher: "open \"\(Defaults[.crossOverFolder].relativePath + "/" + crossoverName).app\""))
        }
        
        addGames(newGames)
    }
    
    func saveSupabaseGameFromName(_ name: String, platform: Platform, launcher: String) async -> Game {
        var newGame = Game(id: UUID(), launcher: launcher, name: name, platform: platform)
        // Create a set of the current game names to prevent duplicates
        await self.supabaseViewModel.fetchGamesFromName(name: name) { fetchedGames in
            if let supabaseGame = fetchedGames.sorted(by: { $0.igdb_id < $1.igdb_id }).first(where: {$0.name == name}) {
                self.supabaseViewModel.convertSupabaseGame(supabaseGame: supabaseGame, game: newGame) { game in
                    newGame = game
                }
            }
        }
        return newGame
    }
}
