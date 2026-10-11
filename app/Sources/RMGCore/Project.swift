import Foundation

/// Where RunMyGames lives online.
public enum Project {
    public static let repo = "Rani367/runmygames"
    public static let homepage = URL(string: "https://github.com/\(repo)")!
    public static let issues = URL(string: "https://github.com/\(repo)/issues/new/choose")!
    public static let compatList = URL(string: "https://github.com/\(repo)/blob/main/compat/games.json")!
    public static let releases = URL(string: "https://github.com/\(repo)/releases")!
    public static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash"
    public static let gptk = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
}
