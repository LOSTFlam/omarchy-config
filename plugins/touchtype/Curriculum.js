// Level definitions and drill-text generation for the Touch Type trainer.
// Pure JS, no Quickshell/QML imports, and no dependency on other .js
// library files — callers (TouchType.qml) import Corpus.js separately and
// pass word lists / punctuation in explicitly. This keeps each script a
// self-contained library, matching how other plugins in this shell keep
// their model scripts import-free of each other.
.pragma library

// Each level:
//   id            stable identifier, used as the progress-store key
//   title/subtitle shown in the level-select screen
//   mode          "chars" | "words" | "mixed" | "sentences"
//   keys          (chars mode) key set to drill
//   wordList      (words/mixed mode) which corpus bucket name to draw from
//   count         (words/mixed/sentences mode) number of words/sentences
//   length        (chars mode) approximate number of non-space characters
//   passAccuracy  minimum accuracy percentage to pass and unlock the next level
//   passWpm       minimum words-per-minute to pass (0 = no speed requirement)
function levels(punctuationChars) {
  return [
    {
      id: "anchors", title: "F & J Anchors", subtitle: "Find home by feel",
      mode: "chars", keys: ["f", "j"], length: 60,
      passAccuracy: 90, passWpm: 0
    },
    {
      id: "homerow", title: "Home Row", subtitle: "A S D F G H J K L ;",
      mode: "chars", keys: ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"], length: 90,
      passAccuracy: 90, passWpm: 0
    },
    {
      id: "homerow-words", title: "Home Row Words", subtitle: "Real words, home keys only",
      mode: "words", wordList: "homeRow", count: 18,
      passAccuracy: 90, passWpm: 10
    },
    {
      id: "toprow", title: "Top Row", subtitle: "Q W E R T   Y U I O P",
      mode: "chars",
      keys: ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "a", "s", "d", "f", "j", "k", "l", ";"],
      length: 100, passAccuracy: 88, passWpm: 0
    },
    {
      id: "toprow-words", title: "Top Row Words", subtitle: "Words without the bottom row",
      mode: "words", wordList: "topRow", count: 20,
      passAccuracy: 88, passWpm: 12
    },
    {
      id: "bottomrow", title: "Bottom Row", subtitle: "Z X C V B   N M , . /",
      mode: "chars",
      keys: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p",
        "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", ",", ".", "/"],
      length: 110, passAccuracy: 85, passWpm: 0
    },
    {
      id: "fullalphabet", title: "Full Alphabet", subtitle: "Every letter, real words",
      mode: "words", wordList: "common", count: 22,
      passAccuracy: 88, passWpm: 15
    },
    {
      id: "numbers", title: "Numbers & Punctuation", subtitle: "0-9 and basic symbols",
      mode: "chars", keys: punctuationChars || [",", ".", ";", "'", "/", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
      length: 90, passAccuracy: 85, passWpm: 0
    },
    {
      id: "mixed", title: "Mixed Drills", subtitle: "Capitals, numbers, punctuation",
      mode: "mixed", wordList: "common", count: 20,
      passAccuracy: 85, passWpm: 15
    },
    {
      id: "sentences", title: "Sentences & Speed", subtitle: "Full sentences, timed",
      mode: "sentences", count: 4,
      passAccuracy: 90, passWpm: 20
    }
  ]
}

// Standard touch-typing finger assignment (letters + home/bottom-row
// punctuation). Numbers-row and symbol assignments live in fingerMeta below.
var fingerKeys = {
  index: ["r", "f", "v", "t", "g", "b", "y", "u", "h", "j", "n", "m"],
  middle: ["e", "d", "c", "i", "k", ","],
  ring: ["w", "s", "x", "o", "l", "."],
  pinky: ["q", "a", "z", "p", ";", "/", "'"]
}

// Fixed pedagogical palette — one hue per finger pair so learners can
// associate colors with fingers. Kept readable on both dark and light
// themes by applying them at low alpha for zones and full for highlights.
var fingerMeta = {
  index: { id: "index", label: "Index fingers", color: "#4fa3e3" },
  middle: { id: "middle", label: "Middle fingers", color: "#5fc184" },
  ring: { id: "ring", label: "Ring fingers", color: "#e5a35c" },
  pinky: { id: "pinky", label: "Pinky fingers", color: "#d67ab1" }
}

var numberKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

var punctuationKeys = [",", ".", ";", "'", "/", "-", "=", "[", "]", "!", "?", ":", "\"", "(", ")"]

// Finger Gym — a beginner track that trains one finger pair (both hands
// together) at a time, easiest first. Letters first for every finger, then
// one combined numbers level and one combined punctuation level.
// Independent unlock chain from the classic track; level ids are namespaced
// with "finger-" so progress never collides with classic levels.
function fingerLevels() {
  return [
    {
      id: "finger-index", track: "finger", finger: "index",
      title: "Index Fingers", subtitle: "R F V T G B · Y U H J N M",
      mode: "chars", keys: fingerKeys.index, length: 80,
      passAccuracy: 90, passWpm: 0
    },
    {
      id: "finger-middle", track: "finger", finger: "middle",
      title: "Middle Fingers", subtitle: "E D C · I K ,",
      mode: "chars", keys: fingerKeys.middle, length: 70,
      passAccuracy: 90, passWpm: 0
    },
    {
      id: "finger-ring", track: "finger", finger: "ring",
      title: "Ring Fingers", subtitle: "W S X · O L .",
      mode: "chars", keys: fingerKeys.ring, length: 70,
      passAccuracy: 90, passWpm: 0
    },
    {
      id: "finger-pinky", track: "finger", finger: "pinky",
      title: "Pinky Fingers", subtitle: "Q A Z · P ; / '",
      mode: "chars", keys: fingerKeys.pinky, length: 70,
      passAccuracy: 90, passWpm: 0
    },
    {
      id: "finger-numbers", track: "finger", finger: "",
      title: "Numbers Row", subtitle: "1–0 across all fingers",
      mode: "chars", keys: numberKeys, length: 90,
      passAccuracy: 85, passWpm: 0
    },
    {
      id: "finger-punct", track: "finger", finger: "",
      title: "Punctuation", subtitle: ", . ; ' / - = [ ] ! ? :",
      mode: "chars", keys: punctuationKeys, length: 90,
      passAccuracy: 85, passWpm: 0
    }
  ]
}

// Maps a drill key to its finger id ("index" | "middle" | "ring" | "pinky"
// | ""). Used to color-code the on-screen keyboard.
function fingerForKey(ch) {
  var lower = (ch || "").toLowerCase()
  for (var finger in fingerKeys) {
    if (fingerKeys[finger].indexOf(lower) !== -1) return finger
  }
  var digitFingers = { "1": "pinky", "2": "ring", "3": "middle", "4": "index", "5": "index", "6": "index", "7": "index", "8": "middle", "9": "ring", "0": "pinky" }
  if (digitFingers[lower] !== undefined) return digitFingers[lower]
  var symbolBase = { "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/" }
  if (symbolBase[lower] !== undefined) return fingerForKey(symbolBase[lower])
  if (["-", "=", "[", "]", "\\", "`"].indexOf(lower) !== -1) return "pinky"
  return ""
}

function levelById(list, id) {
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

function levelIndex(list, id) {
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return i
  return -1
}

function pick(array, rng) {
  return array[Math.floor(rng() * array.length)]
}

function randomChunk(keys, rng, minLen, maxLen) {
  var len = minLen + Math.floor(rng() * (maxLen - minLen + 1))
  var out = ""
  for (var i = 0; i < len; i++) out += pick(keys, rng)
  return out
}

function buildCharsDrill(level, rng) {
  var words = []
  var total = 0
  while (total < level.length) {
    var chunk = randomChunk(level.keys, rng, 2, 5)
    words.push(chunk)
    total += chunk.length
  }
  return words.join(" ")
}

function sampleWords(list, count, rng) {
  var out = []
  for (var i = 0; i < count; i++) out.push(pick(list, rng))
  return out
}

function buildWordsDrill(level, rng, wordListFn) {
  var list = wordListFn(level.wordList)
  return sampleWords(list, level.count, rng).join(" ")
}

function capitalize(word) {
  return word.charAt(0).toUpperCase() + word.slice(1)
}

function buildMixedDrill(level, rng, wordListFn) {
  var list = wordListFn(level.wordList)
  var punctuation = [".", ",", "!"]
  var groups = []
  var remaining = level.count
  while (remaining > 0) {
    var groupLen = Math.min(remaining, 3 + Math.floor(rng() * 4))
    var groupWords = sampleWords(list, groupLen, rng)
    // Occasionally swap the last word for a short number, and always
    // capitalize the first word of the group to mimic real sentence casing.
    if (rng() < 0.35) groupWords[groupWords.length - 1] = String(1 + Math.floor(rng() * 998))
    groupWords[0] = capitalize(groupWords[0])
    var text = groupWords.join(" ") + pick(punctuation, rng)
    groups.push(text)
    remaining -= groupLen
  }
  return groups.join(" ")
}

function buildSentencesDrill(level, rng, sentencePool) {
  var pool = sentencePool.slice()
  var out = []
  for (var i = 0; i < level.count && pool.length > 0; i++) {
    var idx = Math.floor(rng() * pool.length)
    out.push(pool[idx])
    pool.splice(idx, 1)
  }
  return out.join(" ")
}

// Returns the drill text for a level. `rng` defaults to Math.random.
// `wordListFn(name)` and `sentencePool` supply corpus data without this
// script importing Corpus.js directly.
function buildDrill(level, rng, wordListFn, sentencePool) {
  rng = rng || Math.random
  if (level.mode === "chars") return buildCharsDrill(level, rng)
  if (level.mode === "words") return buildWordsDrill(level, rng, wordListFn)
  if (level.mode === "mixed") return buildMixedDrill(level, rng, wordListFn)
  if (level.mode === "sentences") return buildSentencesDrill(level, rng, sentencePool)
  return ""
}
