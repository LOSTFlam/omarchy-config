// Word and sentence banks used to build practice drills. Pure data, no
// QML/Quickshell dependencies, so it can be unit-reasoned about or replaced
// independently of the UI.
.pragma library

// Only uses letters reachable without leaving the home row: a s d f g h j k l.
var homeRowWords = [
  "add", "ads", "ash", "ask", "dad", "dads", "dash", "fads", "fall", "falls",
  "flag", "flags", "flash", "flask", "gala", "gas", "gash", "glad", "glass",
  "half", "halls", "hash", "jag", "jags", "lad", "lads", "lag", "lags",
  "sad", "salad", "salads", "shad", "shall", "alas", "alfalfa", "gaff",
  "gaffs", "hall", "gala", "ask", "gash", "dash"
]

// Common words that avoid the bottom row entirely (no z x c v b n m).
var topRowWords = [
  "the", "that", "this", "they", "are", "for", "you", "your", "our", "out",
  "about", "water", "paper", "tiger", "letter", "garden", "yellow", "potato",
  "jelly", "dollar", "eagle", "purple", "quiet", "quality", "greedy",
  "frosty", "foggy", "guitar", "yogurt", "satellite", "quarter", "forgot",
  "together", "holiday", "today", "reality", "quarry", "outer", "upper"
]

// General common-English word list covering the full alphabet, used for the
// full-alphabet and mixed levels.
var commonWords = [
  "the", "be", "to", "of", "and", "a", "in", "that", "have", "it", "for",
  "not", "on", "with", "he", "as", "you", "do", "at", "this", "but", "his",
  "by", "from", "they", "we", "say", "her", "she", "or", "an", "will", "my",
  "one", "all", "would", "there", "their", "what", "so", "up", "out", "if",
  "about", "who", "get", "which", "go", "me", "when", "make", "can", "like",
  "time", "no", "just", "him", "know", "take", "people", "into", "year",
  "your", "good", "some", "could", "them", "see", "other", "than", "then",
  "now", "look", "only", "come", "its", "over", "think", "also", "back",
  "after", "use", "two", "how", "our", "work", "first", "well", "way",
  "even", "new", "want", "because", "any", "these", "give", "day", "most",
  "us", "zoo", "zip", "exam", "exact", "vivid", "navy", "bench", "much",
  "many", "among", "between", "below", "brave", "brown", "child", "civic",
  "cabin", "dance", "fancy", "magic", "music", "mango", "mixed", "next",
  "number", "object", "vowel", "voice", "value", "view", "vast", "van"
]

var punctuationChars = [
  ",", ".", ";", "'", "/", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
]

var sentences = [
  "The quick brown fox jumps over the lazy dog.",
  "Pack my box with five dozen liquor jugs.",
  "Sphinx of black quartz, judge my vow.",
  "The five boxing wizards jump quickly.",
  "How vexingly quick daft zebras jump!",
  "Bright vixens jump; dozy fowl quack.",
  "Waltz, bad nymph, for quick jigs vex.",
  "Practice makes progress, not perfection.",
  "Type slowly at first, then let speed follow accuracy.",
  "Keep your fingers curved and resting on the home row.",
  "Good posture helps you type for longer without fatigue.",
  "Small steps every day lead to big improvements over time.",
  "Look at the screen, not at your hands, while you type.",
  "A steady rhythm is more valuable than a fast burst.",
  "Consistency beats intensity when you are learning a new skill.",
  "Every expert was once a beginner who kept practicing.",
  "Take a short break if your hands start to feel tired.",
  "Well done! You just finished another training session."
]

function wordList(name) {
  if (name === "homeRow") return homeRowWords
  if (name === "topRow") return topRowWords
  return commonWords
}
