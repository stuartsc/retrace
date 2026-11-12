"""Bounded typed MCP schemas for the implemented native command adapters.

A schema is necessary but insufficient for exposure: native live availability and
per-client grants still filter tools/list and every invocation.
"""

UUID = {"type": "string", "format": "uuid"}
DATE = {"type": "number", "minimum": -62135596800000, "maximum": 253402300799000}
TEXT = {"type": "string", "maxLength": 4096}
BOOL = {"type": "boolean"}


def obj(properties=None, required=()):
    return {
        "type": "object",
        "properties": properties or {},
        "required": list(required),
        "additionalProperties": False,
    }


def nullable(schema):
    return {"anyOf": [schema, {"type": "null"}]}


def command(arguments, destructive=False):
    properties = {"request_id": UUID, "arguments": arguments}
    if destructive:
        properties.update(
            {
                "mode": {"enum": ["execute", "preview"], "default": "preview"},
                "confirmation": nullable(
                    obj(
                        {
                            "previewID": UUID,
                            "digest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                        },
                        ["previewID", "digest"],
                    )
                ),
            }
        )
    return obj(properties, ["request_id", "arguments"])


MARKER_CURSOR = obj({"id": UUID, "anchoredAt": DATE}, ["id", "anchoredAt"])
SCREEN_REF = obj(
    {
        "storeID": UUID,
        "source": {"const": "native"},
        "observationID": UUID,
        "frameID": obj({"value": {"type": "integer", "minimum": 1}}, ["value"]),
        "extractionRevision": {"type": "integer", "minimum": 0},
        "blockIDs": {
            "type": "array",
            "maxItems": 500,
            "items": {"type": "integer", "minimum": 0},
        },
    },
    ["storeID", "source", "observationID", "frameID", "extractionRevision", "blockIDs"],
)
TRANSCRIPT_REF = obj(
    {"version": {"const": 1}, "nativeStoreID": UUID,
     "source": {"enum": ["microphone", "system"]},
     "rowID": {"type": "integer", "minimum": 1},
     "snapshotSHA256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
     "recordingGeneration": {"type": "null"}},
    ["version", "nativeStoreID", "source", "rowID", "snapshotSHA256"],
)
TURN_REF = obj(
    {"version": {"const": 1}, "nativeStoreID": UUID,
     "jobID": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
     "resultSHA256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
     "turnIndex": {"type": "integer", "minimum": 0, "maximum": 4095},
     "correctionRevision": nullable(UUID)},
    ["version", "nativeStoreID", "jobID", "resultSHA256", "turnIndex"],
)
SEARCH_SOURCE_CURSOR = obj(
    {
        "timestamp": DATE,
        "frameID": {"type": "integer"},
        "relevanceRank": nullable({"type": "number"}),
    },
    ["timestamp", "frameID"],
)
SEARCH_CURSOR = obj(
    {
        "native": nullable(SEARCH_SOURCE_CURSOR),
        "rewind": nullable(SEARCH_SOURCE_CURSOR),
        "nativeSearchRevision": nullable({"type": "integer"}),
        "rewindDataVersion": nullable({"type": "integer"}),
        "rewindTotalChanges": nullable({"type": "integer"}),
        "sourceIdentity": nullable(TEXT),
        "queryFingerprint": nullable(TEXT),
    }
)
RULE = obj(
    {
        "id": UUID,
        "revision": UUID,
        "phrase": {"type": "string", "minLength": 1, "maxLength": 256},
        "aliases": {
            "type": "array",
            "maxItems": 16,
            "items": {"type": "string", "minLength": 1, "maxLength": 256},
        },
        "name": {"type": "string", "minLength": 1, "maxLength": 256},
        "meaning": TEXT,
        "enabled": BOOL,
        "action": {"const": "markOnTimeline"},
    },
    ["id", "revision", "phrase", "aliases", "name", "meaning", "enabled", "action"],
)
CONTEXT_RANGE = obj(
    {
        "id": UUID,
        "revision": UUID,
        "start": DATE,
        "end": DATE,
        "explanation": TEXT,
        "ownership": {"enum": ["manual", "pinned"]},
    },
    ["id", "revision", "start", "end", "explanation", "ownership"],
)
ID = obj({"id": UUID}, ["id"])
REVISION_ID = obj({"id": UUID, "expectedRevision": UUID}, ["id", "expectedRevision"])
ANNOTATION_SELECTION = {"selectionID": UUID, "expectedRevision": UUID}
ANNOTATION_ID = {"type": "integer", "minimum": 1}


def annotation_write(action, *, text=False, identifier=False, text_limit=16384):
    properties = {**ANNOTATION_SELECTION, "action": {"const": action}}
    required = ["selectionID", "expectedRevision", "action"]
    if text:
        properties["text"] = {"type": "string", "minLength": 1, "maxLength": text_limit}
        required.append("text")
    if identifier:
        properties["id"] = ANNOTATION_ID
        required.append("id")
    return obj(properties, required)

SCHEMAS = {
    operation: command(obj())
    for operation in [
        "capabilities.read",
        "health.read",
        "usage.read",
        "storage.read",
        "backlog.read",
        "recording.read",
        "settings.read",
        "audio.settings.read",
        "sources.read",
    ]
}
SCHEMAS.update(
    {
        "audio.settings.update": command(obj(
            {"expectedRevision": UUID, "microphoneEnabled": BOOL, "systemAudioEnabled": BOOL},
            ["expectedRevision", "microphoneEnabled", "systemAudioEnabled"],
        )),
        "sources.update": command(obj(
            {"source": {"const": "rewind"}, "enabled": BOOL, "expectedRevision": UUID},
            ["source", "enabled", "expectedRevision"],
        ), destructive=True),
        "retention.apply": command(obj(
            {"cutoff": DATE, "continuationID": nullable(UUID)}, ["cutoff"],
        ), destructive=True),
        "tags.read": command(obj({"references": {"type": "array", "items": SCREEN_REF, "minItems": 1, "maxItems": 16}}, ["references"])),
        "comments.read": command(obj({"references": {"type": "array", "items": SCREEN_REF, "minItems": 1, "maxItems": 16}}, ["references"])),
        "tags.write": command(annotation_write("add", text=True, text_limit=256)),
        "tags.remove": command({"oneOf": [annotation_write("unlink", identifier=True), annotation_write("delete", identifier=True)]}, destructive=True),
        "comments.write": command({"oneOf": [annotation_write("create", text=True), annotation_write("update", text=True, identifier=True), annotation_write("link", identifier=True)]}),
        "comments.remove": command({"oneOf": [annotation_write("unlink", identifier=True), annotation_write("delete", identifier=True)]}, destructive=True),
        "recording.set": command(
            obj(
                {"active": BOOL, "expectedRevision": UUID},
                ["active", "expectedRevision"],
            )
        ),
        "settings.update": command(
            obj(
                {
                    "captureIntervalSeconds": {
                        "type": "number",
                        "minimum": 1,
                        "maximum": 60,
                    },
                    "adaptiveCaptureEnabled": BOOL,
                    "deduplicationThreshold": {"type": "number", "minimum": 0, "maximum": 1},
                    "captureOnWindowChange": BOOL,
                    "excludedAppBundleIDs": {"type": "array", "maxItems": 256, "items": {"type": "string", "minLength": 1, "maxLength": 256}},
                    "redactWindowTitlePatterns": {"type": "array", "maxItems": 128, "items": {"type": "string", "minLength": 1, "maxLength": 512}},
                    "redactBrowserURLPatterns": {"type": "array", "maxItems": 128, "items": {"type": "string", "minLength": 1, "maxLength": 512}},
                    "expectedRevision": UUID,
                },
                [
                    "expectedRevision",
                ],
            )
        ),
        "processing.override": command(obj({"enabled": BOOL}, ["enabled"])),
        "marker.list": command(
            obj(
                {
                    "from": nullable(DATE),
                    "to": nullable(DATE),
                    "before": nullable(MARKER_CURSOR),
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200},
                    "query": {"type": "string", "maxLength": 512},
                }
            )
        ),
        "marker.read": command(ID),
        "marker.create": command(
            obj(
                {"anchoredAt": DATE, "title": nullable(TEXT), "note": nullable(TEXT)},
                ["anchoredAt"],
            )
        ),
        "marker.update": command(
            obj(
                {"id": UUID, "expectedRevision": UUID,
                 "title": {"type": "string", "minLength": 1, "maxLength": 1024},
                 "note": nullable({"type": "string", "maxLength": 16384})},
                ["id", "expectedRevision", "title", "note"],
            )
        ),
        "marker.remove": command(REVISION_ID, destructive=True),
        "marker.restore": command(REVISION_ID),
        "rule.list": command(
            obj(
                {
                    "afterID": nullable(UUID),
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200},
                }
            )
        ),
        "rule.save": command(
            obj({"rule": RULE, "expectedRevision": nullable(UUID)}, ["rule"])
        ),
        "context.read": command(ID),
        "context.revise": command(
            obj(
                {
                    "markerID": UUID,
                    "range": CONTEXT_RANGE,
                    "expectedRevision": nullable(UUID),
                },
                ["markerID", "range"],
            )
        ),
        "evidence.read": command(obj({"reference": SCREEN_REF}, ["reference"])),
        "screenshot.read": command({**obj({
            "reference": SCREEN_REF,
            "offset": {"type": "integer", "minimum": 0, "maximum": 33554431},
            "length": {"type": "integer", "minimum": 1, "maximum": 512000},
            "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        }, ["reference"]), "allOf": [{
            "if": {"required": ["offset"], "properties": {"offset": {"minimum": 1}}},
            "then": {"required": ["sha256"]},
        }]}),
        "evidence.search": command(
            obj(
                {
                    "text": {"type": "string", "minLength": 1, "maxLength": 500},
                    "from": DATE,
                    "to": DATE,
                    "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                    "cursor": nullable(UUID),
                },
                ["text", "from", "to"],
            )
        ),
        "speakers.read": command(obj({"from": DATE, "to": DATE, "cursor": nullable(UUID)}, ["from", "to"])),
        "speaker.correct": command(obj({
            "jobID": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
            "speakerID": {"type": "string", "minLength": 1, "maxLength": 160},
            "displayName": nullable({"type": "string", "minLength": 1, "maxLength": 256}),
            "personID": nullable({"type": "string", "minLength": 1, "maxLength": 128}),
            "expectedRevision": nullable(UUID),
        }, ["jobID", "speakerID"])),
    }
)

SCHEMAS.update(
    {
        "timeline.read": command(
            obj(
                {
                    "from": DATE,
                    "to": DATE,
                    "query": nullable({"type": "string", "maxLength": 512}),
                    "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                    "cursor": nullable(UUID),
                },
                ["from", "to"],
            )
        ),
        "transcript.read": command(
            obj(
                {
                    "from": DATE,
                    "to": DATE,
                    "source": {"enum": ["microphone", "system", None]},
                    "query": nullable({"type": "string", "maxLength": 512}),
                    "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                    "cursor": nullable(UUID),
                },
                ["from", "to"],
            )
        ),
        "context.copy": command(
            obj(
                {
                    "selectionIDs": {
                        "type": "array",
                        "items": UUID,
                        "minItems": 1,
                        "maxItems": 20,
                        "uniqueItems": True,
                    },
                    "question": nullable(TEXT),
                },
                ["selectionIDs"],
            )
        ),
    }
)

SCHEMAS.update(
    {
        "maintenance.request": command(obj()),
        "index.request": command(obj()),
        "processing.repair": command(
            {"oneOf": [obj({"kind": {"const": "pendingTranscription"}}, ["kind"]),
                       obj({"kind": {"const": "ocr"}, "reference": SCREEN_REF}, ["kind", "reference"])]}
        ),
        "job.read": command(ID),
        "job.cancel": command(ID),
        "navigation.open": command(
            {
                "oneOf": [
                    obj({"kind": {"const": "transcript"}, "reference": TRANSCRIPT_REF}, ["kind", "reference"]),
                    obj({"kind": {"const": "speakerTurn"}, "reference": TURN_REF}, ["kind", "reference"]),
                    obj(
                        {"kind": {"const": "screen"}, "reference": SCREEN_REF},
                        ["kind", "reference"],
                    ),
                    obj(
                        {
                            "kind": {"const": "marker"},
                            "id": UUID,
                            "expectedRevision": UUID,
                        },
                        ["kind", "id", "expectedRevision"],
                    ),
                ]
            }
        ),
        "playback.control": command(
            {
                "oneOf": [
                    obj({"action": {"const": "playTurn"}, "reference": TURN_REF}, ["action", "reference"]),
                    obj(
                        {
                            "action": {"const": "play"},
                            "id": UUID,
                            "expectedRevision": UUID,
                        },
                        ["action", "id", "expectedRevision"],
                    ),
                    obj({"action": {"const": "stop"}}, ["action"]),
                ]
            }
        ),
    }
)
