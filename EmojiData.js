// Curated emoji table for Quill's Insert menu.
//
// Plain ES5 with no Qt imports and no network/system lookups, so the picker
// works on any machine and the list can be exercised from node. Every entry
// has the glyph inserted into the note plus a human name and extra searchable
// keywords; filter() matches both, case-insensitively.
var EMOJI = [
  // faces
  { glyph: "😀", name: "grinning face", keywords: "happy smile grin" },
  { glyph: "😃", name: "grinning face big eyes", keywords: "happy smile" },
  { glyph: "😄", name: "grinning face smiling eyes", keywords: "happy laugh" },
  { glyph: "😁", name: "beaming face", keywords: "grin happy" },
  { glyph: "😂", name: "tears of joy", keywords: "laugh cry lol" },
  { glyph: "🤣", name: "rolling on the floor laughing", keywords: "lol rofl" },
  { glyph: "😅", name: "sweat smile", keywords: "nervous laugh" },
  { glyph: "🙂", name: "slightly smiling face", keywords: "smile" },
  { glyph: "🙃", name: "upside down face", keywords: "silly sarcasm" },
  { glyph: "😉", name: "winking face", keywords: "wink flirt" },
  { glyph: "😊", name: "smiling face smiling eyes", keywords: "warm happy" },
  { glyph: "😇", name: "smiling face halo", keywords: "angel innocent" },
  { glyph: "🥰", name: "smiling face hearts", keywords: "love adore" },
  { glyph: "😍", name: "heart eyes", keywords: "love crush" },
  { glyph: "🤩", name: "star struck", keywords: "wow excited" },
  { glyph: "😘", name: "face blowing a kiss", keywords: "love" },
  { glyph: "😋", name: "savoring food", keywords: "yummy tongue" },
  { glyph: "😛", name: "face with tongue", keywords: "silly" },
  { glyph: "🤔", name: "thinking face", keywords: "hmm ponder" },
  { glyph: "🤭", name: "hand over mouth", keywords: "giggle oops" },
  { glyph: "😐", name: "neutral face", keywords: "meh" },
  { glyph: "😏", name: "smirking face", keywords: "smug" },
  { glyph: "🙄", name: "face with rolling eyes", keywords: "whatever" },
  { glyph: "😬", name: "grimacing face", keywords: "awkward" },
  { glyph: "😴", name: "sleeping face", keywords: "tired sleep" },
  { glyph: "🤒", name: "face with thermometer", keywords: "sick fever" },
  { glyph: "🥳", name: "partying face", keywords: "celebrate birthday" },
  { glyph: "🥺", name: "pleading face", keywords: "please puppy" },
  { glyph: "😢", name: "crying face", keywords: "sad tear" },
  { glyph: "😭", name: "loudly crying face", keywords: "sad sob" },
  { glyph: "🤯", name: "exploding head", keywords: "mind blown wow" },
  { glyph: "😱", name: "screaming face", keywords: "shock fear" },

  // gestures
  { glyph: "👍", name: "thumbs up", keywords: "approve like yes" },
  { glyph: "👎", name: "thumbs down", keywords: "dislike no" },
  { glyph: "👌", name: "ok hand", keywords: "perfect" },
  { glyph: "✌️", name: "victory hand", keywords: "peace" },
  { glyph: "🤞", name: "crossed fingers", keywords: "luck hope" },
  { glyph: "🤟", name: "love you gesture", keywords: "sign" },
  { glyph: "🤘", name: "sign of the horns", keywords: "rock" },
  { glyph: "👈", name: "pointing left", keywords: "finger" },
  { glyph: "👉", name: "pointing right", keywords: "finger" },
  { glyph: "👆", name: "pointing up", keywords: "finger" },
  { glyph: "👇", name: "pointing down", keywords: "finger" },
  { glyph: "👋", name: "waving hand", keywords: "hello bye" },
  { glyph: "✋", name: "raised hand", keywords: "stop high five" },
  { glyph: "👏", name: "clapping hands", keywords: "applause" },
  { glyph: "🙏", name: "folded hands", keywords: "please thanks pray" },
  { glyph: "💪", name: "flexed biceps", keywords: "strong muscle" },
  { glyph: "🤝", name: "handshake", keywords: "deal agreement" },

  // hearts
  { glyph: "❤️", name: "red heart", keywords: "love" },
  { glyph: "🧡", name: "orange heart", keywords: "love" },
  { glyph: "💛", name: "yellow heart", keywords: "love" },
  { glyph: "💚", name: "green heart", keywords: "love" },
  { glyph: "💙", name: "blue heart", keywords: "love" },
  { glyph: "💜", name: "purple heart", keywords: "love" },
  { glyph: "🖤", name: "black heart", keywords: "love" },
  { glyph: "🤍", name: "white heart", keywords: "love" },
  { glyph: "🤎", name: "brown heart", keywords: "love" },
  { glyph: "💔", name: "broken heart", keywords: "sad breakup" },
  { glyph: "💕", name: "two hearts", keywords: "love" },
  { glyph: "💖", name: "sparkling heart", keywords: "love" },

  // animals
  { glyph: "🐶", name: "dog face", keywords: "puppy pet" },
  { glyph: "🐱", name: "cat face", keywords: "kitten pet" },
  { glyph: "🐭", name: "mouse face", keywords: "animal" },
  { glyph: "🐹", name: "hamster face", keywords: "pet" },
  { glyph: "🐰", name: "rabbit face", keywords: "bunny" },
  { glyph: "🦊", name: "fox face", keywords: "animal" },
  { glyph: "🐻", name: "bear face", keywords: "animal" },
  { glyph: "🐼", name: "panda face", keywords: "animal" },
  { glyph: "🐨", name: "koala", keywords: "animal" },
  { glyph: "🐯", name: "tiger face", keywords: "animal" },
  { glyph: "🦁", name: "lion face", keywords: "animal" },
  { glyph: "🐮", name: "cow face", keywords: "animal farm" },
  { glyph: "🐷", name: "pig face", keywords: "animal farm" },
  { glyph: "🐸", name: "frog face", keywords: "animal" },
  { glyph: "🐵", name: "monkey face", keywords: "animal" },
  { glyph: "🐧", name: "penguin", keywords: "bird" },
  { glyph: "🦄", name: "unicorn", keywords: "magic horse" },
  { glyph: "🐝", name: "honeybee", keywords: "bee insect" },
  { glyph: "🦋", name: "butterfly", keywords: "insect" },
  { glyph: "🐢", name: "turtle", keywords: "slow" },
  { glyph: "🐬", name: "dolphin", keywords: "sea ocean" },
  { glyph: "🐳", name: "spouting whale", keywords: "sea ocean" },

  // food and drink
  { glyph: "🍎", name: "red apple", keywords: "fruit" },
  { glyph: "🍊", name: "tangerine", keywords: "orange fruit" },
  { glyph: "🍋", name: "lemon", keywords: "fruit sour" },
  { glyph: "🍌", name: "banana", keywords: "fruit" },
  { glyph: "🍉", name: "watermelon", keywords: "fruit" },
  { glyph: "🍇", name: "grapes", keywords: "fruit" },
  { glyph: "🍓", name: "strawberry", keywords: "fruit" },
  { glyph: "🍒", name: "cherries", keywords: "fruit" },
  { glyph: "🍑", name: "peach", keywords: "fruit" },
  { glyph: "🥑", name: "avocado", keywords: "fruit" },
  { glyph: "🍞", name: "bread", keywords: "food loaf" },
  { glyph: "🧀", name: "cheese wedge", keywords: "food" },
  { glyph: "🍕", name: "pizza", keywords: "food" },
  { glyph: "🍔", name: "hamburger", keywords: "burger food" },
  { glyph: "🍣", name: "sushi", keywords: "food" },
  { glyph: "🍜", name: "steaming bowl", keywords: "ramen noodles" },
  { glyph: "🍰", name: "shortcake", keywords: "cake dessert" },
  { glyph: "🍪", name: "cookie", keywords: "biscuit dessert" },
  { glyph: "☕", name: "hot beverage", keywords: "coffee tea" },
  { glyph: "🍺", name: "beer mug", keywords: "drink" },

  // travel and places
  { glyph: "🚗", name: "car", keywords: "drive vehicle" },
  { glyph: "🚌", name: "bus", keywords: "transport" },
  { glyph: "🚲", name: "bicycle", keywords: "bike cycle" },
  { glyph: "✈️", name: "airplane", keywords: "flight travel" },
  { glyph: "🚀", name: "rocket", keywords: "launch space" },
  { glyph: "🛸", name: "flying saucer", keywords: "ufo alien" },
  { glyph: "🚁", name: "helicopter", keywords: "fly" },
  { glyph: "⛵", name: "sailboat", keywords: "boat sea" },
  { glyph: "🚢", name: "ship", keywords: "boat sea" },
  { glyph: "🗺️", name: "world map", keywords: "travel" },
  { glyph: "🧭", name: "compass", keywords: "direction" },
  { glyph: "🏔️", name: "snow capped mountain", keywords: "nature" },
  { glyph: "🏖️", name: "beach umbrella", keywords: "holiday" },
  { glyph: "🏕️", name: "camping", keywords: "tent" },
  { glyph: "🗼", name: "tokyo tower", keywords: "japan city" },
  { glyph: "🏰", name: "castle", keywords: "building" },
  { glyph: "🌍", name: "globe europe africa", keywords: "earth world" },
  { glyph: "🌙", name: "crescent moon", keywords: "night" },
  { glyph: "☀️", name: "sun", keywords: "sunny weather" },
  { glyph: "⭐", name: "star", keywords: "favourite" },
  { glyph: "🌈", name: "rainbow", keywords: "weather" },
  { glyph: "❄️", name: "snowflake", keywords: "cold winter" },
  { glyph: "🔥", name: "fire", keywords: "hot flame" },

  // objects
  { glyph: "💻", name: "laptop", keywords: "computer" },
  { glyph: "⌨️", name: "keyboard", keywords: "computer typing" },
  { glyph: "📱", name: "mobile phone", keywords: "smartphone" },
  { glyph: "📷", name: "camera", keywords: "photo" },
  { glyph: "🎧", name: "headphone", keywords: "music audio" },
  { glyph: "🎸", name: "guitar", keywords: "music" },
  { glyph: "🎹", name: "musical keyboard", keywords: "piano music" },
  { glyph: "📚", name: "books", keywords: "read study" },
  { glyph: "📖", name: "open book", keywords: "read" },
  { glyph: "✏️", name: "pencil", keywords: "write edit" },
  { glyph: "📝", name: "memo", keywords: "note write" },
  { glyph: "📌", name: "pushpin", keywords: "pin" },
  { glyph: "📎", name: "paperclip", keywords: "attach" },
  { glyph: "🔒", name: "locked", keywords: "lock security" },
  { glyph: "🔑", name: "key", keywords: "unlock" },
  { glyph: "💡", name: "light bulb", keywords: "idea" },
  { glyph: "🔨", name: "hammer", keywords: "tool" },
  { glyph: "🧪", name: "test tube", keywords: "science lab" },
  { glyph: "🔬", name: "microscope", keywords: "science" },
  { glyph: "💾", name: "floppy disk", keywords: "save" },
  { glyph: "⏰", name: "alarm clock", keywords: "time" },

  // symbols
  { glyph: "✅", name: "check mark button", keywords: "done yes tick" },
  { glyph: "❌", name: "cross mark", keywords: "no wrong" },
  { glyph: "⚠️", name: "warning", keywords: "caution alert" },
  { glyph: "❓", name: "question mark", keywords: "help" },
  { glyph: "❗", name: "exclamation mark", keywords: "important" },
  { glyph: "💯", name: "hundred points", keywords: "perfect score" },
  { glyph: "🔴", name: "red circle", keywords: "dot" },
  { glyph: "🟢", name: "green circle", keywords: "dot" },
  { glyph: "🔵", name: "blue circle", keywords: "dot" },
  { glyph: "⚡", name: "high voltage", keywords: "zap lightning" },
  { glyph: "✨", name: "sparkles", keywords: "magic shine" },
  { glyph: "🎉", name: "party popper", keywords: "celebrate" },
  { glyph: "🏆", name: "trophy", keywords: "win award" },
  { glyph: "🎯", name: "bullseye", keywords: "target goal" },
  { glyph: "🔔", name: "bell", keywords: "notify alert" },
  { glyph: "👀", name: "eyes", keywords: "look watch" },
  { glyph: "💬", name: "speech balloon", keywords: "chat comment" },

  // flags
  { glyph: "🏳️", name: "white flag", keywords: "surrender" },
  { glyph: "🏁", name: "chequered flag", keywords: "finish race" },
  { glyph: "🚩", name: "triangular flag", keywords: "marker" },
  { glyph: "🇦🇺", name: "Australia flag", keywords: "country" },
  { glyph: "🇧🇷", name: "Brazil flag", keywords: "country" },
  { glyph: "🇨🇦", name: "Canada flag", keywords: "country" },
  { glyph: "🇨🇳", name: "China flag", keywords: "country" },
  { glyph: "🇫🇷", name: "France flag", keywords: "country" },
  { glyph: "🇩🇪", name: "Germany flag", keywords: "country" },
  { glyph: "🇯🇵", name: "Japan flag", keywords: "country" },
  { glyph: "🇬🇧", name: "United Kingdom flag", keywords: "britain uk country" },
  { glyph: "🇺🇸", name: "United States flag", keywords: "america usa country" }
]

function all() {
  return EMOJI
}

function filter(query) {
  var wanted = String(query === undefined || query === null ? "" : query)
    .trim().toLowerCase()
  if (wanted === "") return EMOJI
  var output = []
  for (var i = 0; i < EMOJI.length; i++) {
    var item = EMOJI[i]
    var haystack = (item.name + " " + item.keywords).toLowerCase()
    if (haystack.indexOf(wanted) < 0) continue
    output.push(item)
  }
  return output
}
