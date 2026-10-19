/*
 * scene.cpp — ABI v3 : session « scène » (presets, configuration, plateau,
 * slicing incrémental, mouvements du G-code).
 *
 * Tout passe par les classes que QIDISlicer desktop utilise déjà :
 *   PresetBundle      héritages + conditions de compatibilité des presets
 *   Model/ModelObject objets et instances posés sur le plateau
 *   Print             apply() n'invalide que ce qui a changé
 *   GCodeProcessor    durées, filament, mouvements
 */
#include "ctx.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <locale>
#include <sstream>

#include "libslic3r/Utils.hpp"
#include "libslic3r/FileReader.hpp"
#include "libslic3r/BuildVolume.hpp"
#include "libslic3r/MultipleBeds.hpp"
#include "libslic3r/TriangleMesh.hpp"
#include "libslic3r/Geometry.hpp"
#include "libslic3r/GCode/ThumbnailData.hpp"
#include <arrange-wrapper/ModelArrange.hpp>

using qsid::set_err;
using qsid::dup_string;

namespace {

// ---------------------------------------------------------------- JSON minimal

std::string jstr(const std::string &s)
{
    std::string out = "\"";
    for (unsigned char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n";  break;
        case '\r': out += "\\r";  break;
        case '\t': out += "\\t";  break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

std::string jnum(double v)
{
    if (!std::isfinite(v))
        return "0";
    std::ostringstream os;
    os.imbue(std::locale::classic());
    os.precision(9);
    os << v;
    return os.str();
}

std::string jvec(const Slic3r::Vec3d &v)
{
    return "[" + jnum(v.x()) + "," + jnum(v.y()) + "," + jnum(v.z()) + "]";
}

constexpr double kRad2Deg = 180.0 / M_PI;
constexpr double kDeg2Rad = M_PI / 180.0;

// ---------------------------------------------------------------- aides

/* Libère le drapeau `slicing` à la sortie. */
struct BusyCheck {
    qsid_ctx *ctx;
    bool ok;
    explicit BusyCheck(qsid_ctx *c) : ctx(c), ok(!c->slicing.load()) {}
};

#define QSID_REQUIRE_CTX(ctx) \
    if (!(ctx) || !(ctx)->initialized) return QSID_ERR_NO_CONTEXT
#define QSID_REQUIRE_IDLE(ctx) \
    if ((ctx)->slicing.load()) return QSID_ERR_BUSY

Slic3r::DynamicPrintConfig effective_config(const qsid_ctx *ctx)
{
    Slic3r::DynamicPrintConfig cfg = Slic3r::DynamicPrintConfig::full_print_config();
    cfg.apply(ctx->base_config, true);
    for (const auto &kv : ctx->overrides) {
        Slic3r::ConfigSubstitutionContext sc{Slic3r::ForwardCompatibilitySubstitutionRule::Disable};
        cfg.set_deserialize(kv.first, kv.second, sc);
    }
    return cfg;
}

std::string config_to_json(const Slic3r::ConfigBase &cfg)
{
    std::string out = "{";
    bool first = true;
    for (const std::string &key : cfg.keys()) {
        if (!first)
            out += ",";
        first = false;
        out += jstr(key) + ":" + jstr(cfg.opt_serialize(key));
    }
    return out + "}";
}

struct BedInfo {
    Slic3r::Pointfs   shape;
    Slic3r::BoundingBoxf box;
    double            max_height = 250.0;
};

BedInfo bed_info(const Slic3r::DynamicPrintConfig &cfg)
{
    BedInfo b;
    if (auto *opt = cfg.option<Slic3r::ConfigOptionPoints>("bed_shape"))
        b.shape = opt->values;
    if (b.shape.empty())
        b.shape = {{0, 0}, {200, 0}, {200, 200}, {0, 200}};
    b.box = Slic3r::BoundingBoxf(b.shape);
    if (auto *h = cfg.option<Slic3r::ConfigOptionFloat>("max_print_height"))
        b.max_height = h->value;
    return b;
}

Slic3r::ModelObject *find_object(qsid_ctx *ctx, uint64_t id)
{
    for (Slic3r::ModelObject *o : ctx->model.objects)
        if (o->id().id == id)
            return o;
    return nullptr;
}

bool instance_outside(const Slic3r::ModelObject *o, size_t idx, const BedInfo &bed)
{
    const Slic3r::BoundingBoxf3 bb = o->instance_bounding_box(idx);
    constexpr double eps = 1e-3;
    return bb.min.x() < bed.box.min.x() - eps || bb.max.x() > bed.box.max.x() + eps ||
           bb.min.y() < bed.box.min.y() - eps || bb.max.y() > bed.box.max.y() + eps ||
           bb.max.z() > bed.max_height + eps;
}

/* Place les objets `fresh` sur la première position libre du plateau (balayage
 * par pas de 5 mm), sans déplacer les objets déjà posés. Retourne false si le
 * plateau est plein. */
bool place_without_overlap(Slic3r::Model &model, const std::vector<Slic3r::ModelObject *> &fresh,
                           const BedInfo &bed, double gap)
{
    auto overlaps = [&](const Slic3r::BoundingBoxf3 &cand, const Slic3r::ModelObject *self) {
        for (const Slic3r::ModelObject *o : model.objects) {
            if (o == self || std::find(fresh.begin(), fresh.end(), o) != fresh.end())
                continue;
            for (size_t i = 0; i < o->instances.size(); ++i) {
                const Slic3r::BoundingBoxf3 bb = o->instance_bounding_box(i);
                if (cand.min.x() < bb.max.x() + gap && cand.max.x() > bb.min.x() - gap &&
                    cand.min.y() < bb.max.y() + gap && cand.max.y() > bb.min.y() - gap)
                    return true;
            }
        }
        return false;
    };

    std::vector<const Slic3r::ModelObject *> placed;
    bool all = true;
    for (Slic3r::ModelObject *o : fresh) {
        for (size_t i = 0; i < o->instances.size(); ++i) {
            const Slic3r::BoundingBoxf3 bb = o->instance_bounding_box(i);
            const Slic3r::Vec3d size = bb.size();
            const Slic3r::Vec3d center_shift = o->instances[i]->get_offset() - bb.center();
            bool found = false;
            constexpr double step = 5.0;
            for (double y = bed.box.min.y(); y + size.y() <= bed.box.max.y() + 1e-6 && !found; y += step) {
                for (double x = bed.box.min.x(); x + size.x() <= bed.box.max.x() + 1e-6 && !found; x += step) {
                    Slic3r::BoundingBoxf3 cand(Slic3r::Vec3d(x, y, bb.min.z()),
                                               Slic3r::Vec3d(x + size.x(), y + size.y(), bb.max.z()));
                    if (overlaps(cand, o))
                        continue;
                    bool clash = false;
                    for (const Slic3r::ModelObject *p : placed)
                        for (size_t k = 0; k < p->instances.size() && !clash; ++k) {
                            const Slic3r::BoundingBoxf3 pb = p->instance_bounding_box(k);
                            clash = cand.min.x() < pb.max.x() + gap && cand.max.x() > pb.min.x() - gap &&
                                    cand.min.y() < pb.max.y() + gap && cand.max.y() > pb.min.y() - gap;
                        }
                    if (clash)
                        continue;
                    Slic3r::Vec3d offset = cand.center() + center_shift;
                    offset.z() = o->instances[i]->get_offset().z();
                    o->instances[i]->set_offset(offset);
                    o->invalidate_bounding_box();
                    found = true;
                }
            }
            if (!found)
                all = false;
        }
        placed.push_back(o);
    }
    return all;
}

void arrange_all(qsid_ctx *ctx, const Slic3r::DynamicPrintConfig &cfg)
{
    const Slic3r::Vec2crd gap{Slic3r::s_multiple_beds.get_bed_gap()};
    Slic3r::arr2::ArrangeBed bed = Slic3r::arr2::to_arrange_bed(Slic3r::get_bed_shape(cfg), gap);
    Slic3r::arr2::ArrangeSettings settings;
    settings.set_distance_from_objects(Slic3r::min_object_distance(cfg));
    Slic3r::arrange_objects(ctx->model, bed, settings);
}

void update_volume_state(qsid_ctx *ctx, const Slic3r::DynamicPrintConfig &cfg)
{
    const BedInfo bed = bed_info(cfg);
    Slic3r::BuildVolume build_volume(bed.shape, bed.max_height);
    Slic3r::s_multiple_beds.update_build_volume(Slic3r::BoundingBoxf(bed.shape));
    ctx->model.update_print_volume_state(build_volume);
}

const char *kind_name(const std::string &kind)
{
    return kind.c_str();
}

Slic3r::PresetCollection *collection_for(Slic3r::PresetBundle &b, const std::string &kind)
{
    if (kind == "printer")  return &b.printers;
    if (kind == "print")    return &b.prints;
    if (kind == "filament") return &b.filaments;
    return nullptr;
}

} // namespace

extern "C" {

void qsid_free(void *p)
{
    std::free(p);
}

// ============================================================ Presets

int qsid_presets_load(qsid_ctx *ctx, const char *vendor_ini, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    if (!vendor_ini || !*vendor_ini)
        return QSID_ERR_ARG;
    try {
        auto bundle = std::make_unique<Slic3r::PresetBundle>();
        const auto result = bundle->load_configbundle(
            vendor_ini, Slic3r::PresetBundle::LoadConfigBundleAttribute::LoadSystem,
            Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent);
        if (result.second == 0) {
            set_err(err_msg, err_len, std::string("no preset loaded from ") + vendor_ini);
            return QSID_ERR_IO;
        }
        ctx->presets = std::move(bundle);
        ctx->base_from_ini = false;
        return QSID_OK;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_IO;
    }
}

int qsid_presets_list(qsid_ctx *ctx, const char *kind, char **out_json, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    if (!kind || !out_json)
        return QSID_ERR_ARG;
    if (!ctx->presets) {
        set_err(err_msg, err_len, "presets not loaded");
        return QSID_ERR_ARG;
    }
    Slic3r::PresetCollection *col = collection_for(*ctx->presets, kind);
    if (!col) {
        set_err(err_msg, err_len, std::string("unknown kind: ") + kind);
        return QSID_ERR_ARG;
    }
    std::string out = "[";
    bool first = true;
    for (const Slic3r::Preset &p : *col) {
        if (p.is_default || !p.is_visible || !p.is_compatible)
            continue;
        if (!first)
            out += ",";
        first = false;
        out += jstr(p.name);
    }
    out += "]";
    *out_json = dup_string(out);
    return *out_json ? QSID_OK : QSID_ERR_ARG;
}

int qsid_presets_select(qsid_ctx *ctx, const char *printer, const char *print, const char *filament,
                        char **out_json, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    if (!ctx->presets) {
        set_err(err_msg, err_len, "presets not loaded");
        return QSID_ERR_ARG;
    }
    try {
        Slic3r::PresetBundle &b = *ctx->presets;
        using Compat = Slic3r::PresetSelectCompatibleType;

        // Même enchaînement que l'interface : l'imprimante d'abord, puis la
        // compatibilité (le moteur remplace un preset devenu incompatible), puis
        // l'impression, puis le filament.
        if (printer && *printer) {
            if (!b.printers.select_preset_by_name(printer, true)) {
                set_err(err_msg, err_len, std::string("unknown printer preset: ") + printer);
                return QSID_ERR_ARG;
            }
            b.update_multi_material_filament_presets();
        } else if (b.printers.get_selected_preset().is_default) {
            // rien de sélectionné : premier preset concret
            for (const Slic3r::Preset &p : b.printers)
                if (!p.is_default && p.is_visible) {
                    b.printers.select_preset_by_name(p.name, true);
                    b.update_multi_material_filament_presets();
                    break;
                }
        }
        b.update_compatible(Compat::Always);

        if (print && *print) {
            const Slic3r::Preset *p = b.prints.find_preset(print, false, false);
            if (p && p->is_compatible)
                b.prints.select_preset_by_name(print, true);
        }
        b.update_compatible(Compat::Never, Compat::Always);

        if (filament && *filament) {
            const Slic3r::Preset *f = b.filaments.find_preset(filament, false, false);
            if (f && f->is_compatible)
                b.set_filament_preset(0, filament);
        }

        ctx->base_config = b.full_config();
        ctx->base_from_ini = false;
        ctx->print.reset();   // un autre preset : on repart d'un Print neuf

        if (out_json) {
            std::string out = "{\"printer\":" + jstr(b.printers.get_selected_preset_name()) +
                              ",\"print\":" + jstr(b.prints.get_selected_preset_name()) +
                              ",\"filament\":" + jstr(b.filaments.get_selected_preset_name()) + "}";
            *out_json = dup_string(out);
        }
        return QSID_OK;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_SLICE_FAILED;
    }
}

int qsid_config_load_ini(qsid_ctx *ctx, const char *path, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    if (!path || !*path)
        return QSID_ERR_ARG;
    try {
        Slic3r::DynamicPrintConfig cfg = Slic3r::DynamicPrintConfig::full_print_config();
        Slic3r::DynamicPrintConfig user;
        user.load_from_ini(path, Slic3r::ForwardCompatibilitySubstitutionRule::EnableSystemSilent);
        cfg.apply(user);
        ctx->base_config = std::move(cfg);
        ctx->base_from_ini = true;
        ctx->print.reset();
        return QSID_OK;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_IO;
    }
}

// ============================================================ Configuration

int qsid_config_base(qsid_ctx *ctx, char **out_json)
{
    QSID_REQUIRE_CTX(ctx);
    if (!out_json)
        return QSID_ERR_ARG;
    Slic3r::DynamicPrintConfig cfg = Slic3r::DynamicPrintConfig::full_print_config();
    cfg.apply(ctx->base_config, true);
    *out_json = dup_string(config_to_json(cfg));
    return *out_json ? QSID_OK : QSID_ERR_ARG;
}

int qsid_config_effective(qsid_ctx *ctx, char **out_json)
{
    QSID_REQUIRE_CTX(ctx);
    if (!out_json)
        return QSID_ERR_ARG;
    *out_json = dup_string(config_to_json(effective_config(ctx)));
    return *out_json ? QSID_OK : QSID_ERR_ARG;
}

int qsid_config_overrides(qsid_ctx *ctx, char **out_json)
{
    QSID_REQUIRE_CTX(ctx);
    if (!out_json)
        return QSID_ERR_ARG;
    std::string out = "{";
    bool first = true;
    for (const auto &kv : ctx->overrides) {
        if (!first)
            out += ",";
        first = false;
        out += jstr(kv.first) + ":" + jstr(kv.second);
    }
    *out_json = dup_string(out + "}");
    return *out_json ? QSID_OK : QSID_ERR_ARG;
}

int qsid_config_set(qsid_ctx *ctx, const char *key, const char *value, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    if (!key || !*key || !value)
        return QSID_ERR_ARG;
    try {
        Slic3r::DynamicPrintConfig probe = effective_config(ctx);
        if (!probe.has(key)) {
            set_err(err_msg, err_len, std::string("unknown option: ") + key);
            return QSID_ERR_ARG;
        }
        Slic3r::ConfigSubstitutionContext sc{Slic3r::ForwardCompatibilitySubstitutionRule::Disable};
        probe.set_deserialize(key, value, sc);
        const std::string canonical = probe.opt_serialize(key);

        Slic3r::DynamicPrintConfig base = Slic3r::DynamicPrintConfig::full_print_config();
        base.apply(ctx->base_config, true);
        if (base.opt_serialize(key) == canonical)
            ctx->overrides.erase(key);
        else
            ctx->overrides[key] = canonical;
        return QSID_OK;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_ARG;
    }
}

int qsid_config_reset(qsid_ctx *ctx, const char *key)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    if (!key || !*key)
        ctx->overrides.clear();
    else
        ctx->overrides.erase(key);
    return QSID_OK;
}

int qsid_config_schema(qsid_ctx *ctx, char **out_json)
{
    QSID_REQUIRE_CTX(ctx);
    if (!out_json)
        return QSID_ERR_ARG;

    static const char *const type_names[] = {
        "unknown", "float", "floats", "int", "ints", "string", "strings", "percent", "percents",
        "float_or_percent", "floats_or_percents", "point", "points", "point3", "bool", "bools",
        "enum", "enums"
    };

    std::string out = "[";
    bool first = true;
    for (const auto &entry : Slic3r::print_config_def.options) {
        const Slic3r::ConfigOptionDef &def = entry.second;
        if (def.label.empty() && def.full_label.empty())
            continue;   // option interne (pas dans l'interface)
        if (!first)
            out += ",";
        first = false;

        const size_t t = static_cast<size_t>(def.type);
        const char *type = "unknown";
        switch (def.type) {
        case Slic3r::coFloat:            type = "float"; break;
        case Slic3r::coFloats:           type = "floats"; break;
        case Slic3r::coInt:              type = "int"; break;
        case Slic3r::coInts:             type = "ints"; break;
        case Slic3r::coString:           type = "string"; break;
        case Slic3r::coStrings:          type = "strings"; break;
        case Slic3r::coPercent:          type = "percent"; break;
        case Slic3r::coPercents:         type = "percents"; break;
        case Slic3r::coFloatOrPercent:   type = "float_or_percent"; break;
        case Slic3r::coFloatsOrPercents: type = "floats_or_percents"; break;
        case Slic3r::coPoint:            type = "point"; break;
        case Slic3r::coPoints:           type = "points"; break;
        case Slic3r::coPoint3:           type = "point3"; break;
        case Slic3r::coBool:             type = "bool"; break;
        case Slic3r::coBools:            type = "bools"; break;
        case Slic3r::coEnum:             type = "enum"; break;
        case Slic3r::coEnums:            type = "enums"; break;
        default: break;
        }
        (void) type_names; (void) t;

        const char *mode = def.mode == Slic3r::comSimple ? "simple"
                         : def.mode == Slic3r::comAdvanced ? "advanced" : "expert";

        out += "{\"key\":" + jstr(entry.first);
        out += ",\"type\":" + jstr(type);
        out += ",\"label\":" + jstr(def.label.empty() ? def.full_label : def.label);
        out += ",\"full_label\":" + jstr(def.full_label);
        out += ",\"tooltip\":" + jstr(def.tooltip);
        out += ",\"category\":" + jstr(def.category);
        out += ",\"sidetext\":" + jstr(def.sidetext);
        out += ",\"mode\":" + jstr(mode);
        out += ",\"nullable\":" + std::string(def.nullable ? "true" : "false");
        out += ",\"multiline\":" + std::string(def.multiline ? "true" : "false");
        out += ",\"readonly\":" + std::string(def.readonly ? "true" : "false");
        if (def.min > -1e30f)
            out += ",\"min\":" + jnum(def.min);
        if (def.max < 1e30f)
            out += ",\"max\":" + jnum(def.max);
        if (def.enum_def && def.enum_def->has_values()) {
            out += ",\"enum_values\":[";
            const auto &values = def.enum_def->values();
            const auto &labels = def.enum_def->labels();
            for (size_t i = 0; i < values.size(); ++i)
                out += (i ? "," : "") + jstr(values[i]);
            out += "],\"enum_labels\":[";
            for (size_t i = 0; i < labels.size(); ++i)
                out += (i ? "," : "") + jstr(labels[i]);
            out += "]";
        }
        if (def.default_value)
            out += ",\"default\":" + jstr(def.default_value->serialize());
        out += "}";
    }
    out += "]";
    *out_json = dup_string(out);
    return *out_json ? QSID_OK : QSID_ERR_ARG;
}

// ============================================================ Scène

int qsid_scene_clear(qsid_ctx *ctx)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    ctx->print.reset();
    ctx->model.clear_objects();
    ctx->has_result = false;
    ctx->last_result = Slic3r::GCodeProcessorResult();
    return QSID_OK;
}

int qsid_scene_add(qsid_ctx *ctx, const char *path, char **out_json, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    if (!path || !*path)
        return QSID_ERR_ARG;
    try {
        Slic3r::FileReader::LoadStats stats;
        Slic3r::Model loaded = Slic3r::FileReader::load_model(path, Slic3r::FileReader::LoadAttribute::AddDefaultInstances, &stats);
        if (loaded.objects.empty()) {
            set_err(err_msg, err_len, "the file contains no printable object");
            return QSID_ERR_IO;
        }

        const std::string lower = [&] {
            std::string s = path;
            std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
            return s;
        }();
        const bool is_3mf = lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".3mf") == 0;

        const Slic3r::DynamicPrintConfig cfg = effective_config(ctx);
        const BedInfo bed = bed_info(cfg);

        std::vector<Slic3r::ModelObject *> fresh;
        std::string added = "[";
        for (Slic3r::ModelObject *src : loaded.objects) {
            Slic3r::ModelObject *o = ctx->model.add_object(*src);
            // Comme Plater::load_files : un fichier de géométrie pure est centré sur
            // son origine (l'instance porte alors la position) ; un 3MF de projet
            // garde ses placements. Dans les deux cas l'objet est posé sur le plateau.
            if (!is_3mf)
                o->center_around_origin();
            o->ensure_on_bed();
            o->invalidate_bounding_box();
            fresh.push_back(o);
            added += (fresh.size() > 1 ? "," : "") + std::to_string(o->id().id);
        }
        added += "]";

        // Placement : 3MF dont tous les objets tiennent déjà sur le plateau = inchangé ;
        // sinon première place libre, objet par objet.
        bool needs_placement = !is_3mf;
        if (is_3mf)
            for (const Slic3r::ModelObject *o : fresh)
                for (size_t i = 0; i < o->instances.size(); ++i)
                    needs_placement = needs_placement || instance_outside(o, i, bed);
        if (needs_placement) {
            // Positions de départ : au centre du plateau (le balayage fait le reste).
            for (Slic3r::ModelObject *o : fresh)
                for (Slic3r::ModelInstance *inst : o->instances) {
                    Slic3r::Vec3d off = inst->get_offset();
                    off.x() = bed.box.center().x();
                    off.y() = bed.box.center().y();
                    inst->set_offset(off);
                }
            for (Slic3r::ModelObject *o : fresh)
                o->invalidate_bounding_box();
            const double gap = Slic3r::min_object_distance(cfg);
            if (!place_without_overlap(ctx->model, fresh, bed, std::max(gap, 2.0))) {
                // Plateau saturé : on laisse le moteur réorganiser l'ensemble.
                arrange_all(ctx, cfg);
            }
        }

        std::string out = "{\"added\":" + added + ",\"alerts\":{";
        out += "\"deleted_objects\":" + std::to_string(stats.deleted_objects_cnt);
        out += ",\"multipart\":" + std::string(stats.looks_like_multipart_object ? "true" : "false");
        out += ",\"saved_in_meters\":" + std::string(stats.looks_like_saved_in_meters ? "true" : "false");
        out += ",\"imperial\":" + std::string(stats.looks_like_imperial_units ? "true" : "false");
        out += "}}";
        if (out_json)
            *out_json = dup_string(out);
        return QSID_OK;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_IO;
    }
}

int qsid_scene_info(qsid_ctx *ctx, char **out_json)
{
    QSID_REQUIRE_CTX(ctx);
    if (!out_json)
        return QSID_ERR_ARG;
    const Slic3r::DynamicPrintConfig cfg = effective_config(ctx);
    const BedInfo bed = bed_info(cfg);

    std::string out = "{\"bed\":{\"shape\":[";
    for (size_t i = 0; i < bed.shape.size(); ++i)
        out += (i ? "," : "") + std::string("[") + jnum(bed.shape[i].x()) + "," + jnum(bed.shape[i].y()) + "]";
    out += "],\"max_height\":" + jnum(bed.max_height) + "},\"objects\":[";

    bool first_obj = true;
    for (Slic3r::ModelObject *o : ctx->model.objects) {
        if (!first_obj)
            out += ",";
        first_obj = false;
        const Slic3r::BoundingBoxf3 local = o->raw_mesh_bounding_box();
        size_t triangles = 0;
        for (const Slic3r::ModelVolume *v : o->volumes)
            if (v->is_model_part())
                triangles += v->mesh().its.indices.size();

        out += "{\"id\":" + std::to_string(o->id().id);
        out += ",\"name\":" + jstr(o->name);
        out += ",\"triangles\":" + std::to_string(triangles);
        out += ",\"local_min\":" + jvec(local.min) + ",\"local_max\":" + jvec(local.max);
        out += ",\"instances\":[";
        for (size_t i = 0; i < o->instances.size(); ++i) {
            const Slic3r::ModelInstance *inst = o->instances[i];
            const Slic3r::BoundingBoxf3 bb = o->instance_bounding_box(i);
            const Slic3r::Transform3d &m = inst->get_matrix();
            out += (i ? "," : "") + std::string("{\"offset\":") + jvec(inst->get_offset());
            out += ",\"rotation_deg\":" + jvec(inst->get_rotation() * kRad2Deg);
            out += ",\"scale\":" + jvec(inst->get_scaling_factor());
            out += ",\"min\":" + jvec(bb.min) + ",\"max\":" + jvec(bb.max);
            out += ",\"outside\":" + std::string(instance_outside(o, i, bed) ? "true" : "false");
            out += ",\"matrix\":[";
            for (int c = 0; c < 4; ++c)
                for (int r = 0; r < 4; ++r)
                    out += ((c || r) ? "," : "") + jnum(m(r, c));
            out += "]}";
        }
        out += "]}";
    }
    out += "]}";
    *out_json = dup_string(out);
    return *out_json ? QSID_OK : QSID_ERR_ARG;
}

int qsid_scene_mesh(qsid_ctx *ctx, uint64_t object_id, float **xyz, size_t *triangle_count,
                    char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    if (!xyz || !triangle_count)
        return QSID_ERR_ARG;
    Slic3r::ModelObject *o = find_object(ctx, object_id);
    if (!o) {
        set_err(err_msg, err_len, "unknown object id");
        return QSID_ERR_ARG;
    }
    const Slic3r::TriangleMesh mesh = o->raw_mesh();
    const auto &its = mesh.its;
    const size_t n = its.indices.size();
    float *buf = static_cast<float *>(std::malloc(std::max<size_t>(n, 1) * 9 * sizeof(float)));
    if (!buf)
        return QSID_ERR_ARG;
    for (size_t t = 0; t < n; ++t)
        for (int v = 0; v < 3; ++v) {
            const Slic3r::Vec3f &p = its.vertices[its.indices[t][v]];
            buf[t * 9 + v * 3 + 0] = p.x();
            buf[t * 9 + v * 3 + 1] = p.y();
            buf[t * 9 + v * 3 + 2] = p.z();
        }
    *xyz = buf;
    *triangle_count = n;
    return QSID_OK;
}

int qsid_scene_set_transform(qsid_ctx *ctx, uint64_t object_id, int instance,
                             const double offset[3], const double rotation_deg[3],
                             const double scale[3], int drop_to_bed)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    Slic3r::ModelObject *o = find_object(ctx, object_id);
    if (!o || instance < 0 || static_cast<size_t>(instance) >= o->instances.size())
        return QSID_ERR_ARG;
    Slic3r::ModelInstance *inst = o->instances[instance];
    if (scale) {
        // Échelle nulle ou négative : refusée (maillage dégénéré).
        for (int i = 0; i < 3; ++i)
            if (!(scale[i] > 1e-6))
                return QSID_ERR_ARG;
        inst->set_scaling_factor(Slic3r::Vec3d(scale[0], scale[1], scale[2]));
    }
    if (rotation_deg)
        inst->set_rotation(Slic3r::Vec3d(rotation_deg[0], rotation_deg[1], rotation_deg[2]) * kDeg2Rad);
    if (offset)
        inst->set_offset(Slic3r::Vec3d(offset[0], offset[1], offset[2]));
    o->invalidate_bounding_box();
    if (drop_to_bed)
        o->ensure_on_bed();
    return QSID_OK;
}

int qsid_scene_remove(qsid_ctx *ctx, uint64_t object_id)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    for (size_t i = 0; i < ctx->model.objects.size(); ++i)
        if (ctx->model.objects[i]->id().id == object_id) {
            ctx->model.delete_object(i);
            return QSID_OK;
        }
    return QSID_ERR_ARG;
}

int qsid_scene_set_instances(qsid_ctx *ctx, uint64_t object_id, int count)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    Slic3r::ModelObject *o = find_object(ctx, object_id);
    if (!o || count < 1 || count > 100)
        return QSID_ERR_ARG;
    while (static_cast<int>(o->instances.size()) > count)
        o->delete_instance(o->instances.size() - 1);
    while (static_cast<int>(o->instances.size()) < count) {
        const Slic3r::BoundingBoxf3 bb = o->instance_bounding_box(o->instances.size() - 1);
        Slic3r::ModelInstance *inst = o->add_instance(*o->instances.back());
        inst->set_offset(inst->get_offset() + Slic3r::Vec3d(bb.size().x() + 5.0, 0, 0));
    }
    o->invalidate_bounding_box();
    return QSID_OK;
}

int qsid_scene_arrange(qsid_ctx *ctx)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    try {
        arrange_all(ctx, effective_config(ctx));
        for (Slic3r::ModelObject *o : ctx->model.objects)
            o->invalidate_bounding_box();
        return QSID_OK;
    } catch (const std::exception &) {
        return QSID_ERR_SLICE_FAILED;
    }
}

int qsid_scene_drop_to_bed(qsid_ctx *ctx, uint64_t object_id)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    Slic3r::ModelObject *o = find_object(ctx, object_id);
    if (!o)
        return QSID_ERR_ARG;
    o->ensure_on_bed();
    o->invalidate_bounding_box();
    return QSID_OK;
}

int qsid_scene_lay_on_face(qsid_ctx *ctx, uint64_t object_id, int instance, size_t triangle,
                           char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    QSID_REQUIRE_IDLE(ctx);
    Slic3r::ModelObject *o = find_object(ctx, object_id);
    if (!o || instance < 0 || static_cast<size_t>(instance) >= o->instances.size())
        return QSID_ERR_ARG;
    const Slic3r::TriangleMesh mesh = o->raw_mesh();
    if (triangle >= mesh.its.indices.size()) {
        set_err(err_msg, err_len, "triangle index out of range");
        return QSID_ERR_ARG;
    }
    Slic3r::ModelInstance *inst = o->instances[instance];

    const auto &its = mesh.its;
    const Slic3r::Vec3d a = its.vertices[its.indices[triangle][0]].cast<double>();
    const Slic3r::Vec3d b = its.vertices[its.indices[triangle][1]].cast<double>();
    const Slic3r::Vec3d c = its.vertices[its.indices[triangle][2]].cast<double>();
    Slic3r::Vec3d normal_local = (b - a).cross(c - a);
    if (normal_local.norm() < 1e-12) {
        set_err(err_msg, err_len, "degenerate triangle");
        return QSID_ERR_ARG;
    }

    // Normale dans le repère monde : inverse-transposée de la partie linéaire (gère
    // une échelle non uniforme).
    const Slic3r::Matrix3d linear = inst->get_matrix_no_offset().linear();
    Slic3r::Vec3d normal_world = (linear.inverse().transpose() * normal_local).normalized();

    const Eigen::Quaterniond q = Eigen::Quaterniond::FromTwoVectors(normal_world, Slic3r::Vec3d(0, 0, -1));
    Slic3r::Transform3d m = Slic3r::Transform3d::Identity();
    m.translate(inst->get_offset());
    m.rotate(q);
    m = m * inst->get_matrix_no_offset();
    inst->set_transformation(Slic3r::Geometry::Transformation(m));
    o->invalidate_bounding_box();
    o->ensure_on_bed();
    return QSID_OK;
}

// ============================================================ Slicing

namespace {

std::string role_name(int r)
{
    static const char *names[] = {"none", "perimeter", "external_perimeter", "overhang_perimeter",
        "internal_infill", "solid_infill", "top_solid_infill", "ironing", "bridge_infill", "gap_fill",
        "skirt", "support_material", "support_material_interface", "wipe_tower", "custom"};
    return (r >= 0 && r < 15) ? names[r] : "none";
}

std::string build_summary(const Slic3r::Print &print, const Slic3r::GCodeProcessorResult &result)
{
    const Slic3r::PrintStatistics &st = print.print_statistics();

    uint32_t layers = 0;
    std::map<int, double> time_by_role;
    for (const auto &mv : result.moves) {
        layers = std::max<uint32_t>(layers, mv.layer_id + 1);
        if (mv.type == Slic3r::EMoveType::Extrude)
            time_by_role[static_cast<int>(mv.extrusion_role)] += mv.time[0];
    }

    std::string out = "{";
    out += "\"time_normal_s\":" + jnum(st.normal_print_time_seconds);
    out += ",\"time_silent_s\":" + jnum(st.silent_print_time_seconds);
    out += ",\"time_normal\":" + jstr(st.estimated_normal_print_time);
    out += ",\"time_silent\":" + jstr(st.estimated_silent_print_time);
    out += ",\"filament_mm\":" + jnum(st.total_used_filament);
    out += ",\"filament_cm3\":" + jnum(st.total_extruded_volume / 1000.0);
    out += ",\"filament_g\":" + jnum(st.total_weight);
    out += ",\"cost\":" + jnum(st.total_cost);
    out += ",\"toolchanges\":" + std::to_string(st.total_toolchanges);
    out += ",\"layers\":" + std::to_string(layers);
    out += ",\"moves\":" + std::to_string(result.moves.size());
    out += ",\"roles\":[";
    bool first = true;
    for (const auto &kv : time_by_role) {
        double mm = 0, g = 0;
        auto it = result.print_statistics.used_filaments_per_role.find(static_cast<Slic3r::GCodeExtrusionRole>(kv.first));
        if (it != result.print_statistics.used_filaments_per_role.end()) {
            mm = it->second.first;   // m dans le moteur, converti plus bas
            g  = it->second.second;
        }
        out += (first ? "" : ",") + std::string("{\"role\":") + std::to_string(kv.first);
        out += ",\"name\":" + jstr(role_name(kv.first));
        out += ",\"time_s\":" + jnum(kv.second);
        out += ",\"filament_m\":" + jnum(mm) + ",\"filament_g\":" + jnum(g) + "}";
        first = false;
    }
    out += "]";
    out += ",\"warnings\":[";
    first = true;
    if (result.conflict_result.has_value()) {
        out += jstr("Collision between objects " + result.conflict_result->_objName1 + " and " +
                    result.conflict_result->_objName2);
        first = false;
    }
    if (result.sequential_collision_detected.has_value())
        out += (first ? "" : ",") + jstr("Sequential printing collision");
    out += "]}";
    return out;
}

} // namespace

int qsid_slice_scene(qsid_ctx *ctx, const char *out_gcode, qsid_progress_cb cb, void *user,
                     char **out_summary_json, char *err_msg, size_t err_len)
{
    QSID_REQUIRE_CTX(ctx);
    if (!out_gcode || !*out_gcode)
        return QSID_ERR_ARG;

    bool expected = false;
    if (!ctx->slicing.compare_exchange_strong(expected, true))
        return QSID_ERR_BUSY;
    struct Guard {
        std::atomic<bool> &flag;
        ~Guard() { flag.store(false); }
    } guard{ctx->slicing};

    ctx->cancel_requested.store(false);
    ctx->has_result = false;
    std::remove(out_gcode);

    try {
        if (ctx->model.objects.empty()) {
            set_err(err_msg, err_len, "the scene is empty: import a model first");
            return QSID_ERR_SLICE_FAILED;
        }
        if (!ctx->print)
            ctx->print = std::make_unique<Slic3r::Print>();
        Slic3r::Print &print = *ctx->print;

        {
            std::lock_guard<std::mutex> lock(ctx->print_mutex);
            ctx->current_print = &print;
        }
        struct PrintGuard {
            qsid_ctx *c;
            ~PrintGuard() {
                std::lock_guard<std::mutex> lock(c->print_mutex);
                c->current_print = nullptr;
            }
        } print_guard{ctx};

        print.set_status_callback([ctx, cb, user](const Slic3r::PrintBase::SlicingStatus &status) {
            if (ctx->cancel_requested.load(std::memory_order_relaxed))
                return;
            if (cb)
                cb(status.percent, status.text.c_str(), user);
        });

        const Slic3r::DynamicPrintConfig cfg = effective_config(ctx);
        for (Slic3r::ModelObject *mo : ctx->model.objects)
            print.auto_assign_extruders(mo);
        update_volume_state(ctx, cfg);

        Slic3r::MultipleBedsUtils::with_single_bed_model_fff(ctx->model, 0, [&]() {
            print.apply(ctx->model, cfg);
        });

        if (const std::string validation = print.validate(); !validation.empty()) {
            set_err(err_msg, err_len, validation);
            return QSID_ERR_SLICE_FAILED;
        }
        if (print.empty()) {
            set_err(err_msg, err_len, "nothing to print: the objects are empty or outside the print volume");
            return QSID_ERR_SLICE_FAILED;
        }
        if (ctx->cancel_requested.load()) {
            set_err(err_msg, err_len, "canceled");
            return QSID_ERR_CANCELED;
        }

        print.process();
        if (ctx->cancel_requested.load()) {
            set_err(err_msg, err_len, "canceled");
            return QSID_ERR_CANCELED;
        }

        // Vignettes : rendues par l'hôte (SceneKit) si un fournisseur est installé.
        Slic3r::ThumbnailsGeneratorCallback thumbnails = [ctx](const Slic3r::ThumbnailsParams &params) {
            Slic3r::ThumbnailsList list;
            if (!ctx->thumbnail_cb)
                return list;
            for (const Slic3r::Vec2d &size : params.sizes) {
                const int w = static_cast<int>(size.x()), h = static_cast<int>(size.y());
                if (w <= 0 || h <= 0 || w > 2048 || h > 2048)
                    continue;
                std::vector<uint8_t> rgba(static_cast<size_t>(w) * h * 4, 0);
                if (!ctx->thumbnail_cb(w, h, rgba.data(), ctx->thumbnail_user))
                    continue;
                Slic3r::ThumbnailData data;
                data.set(w, h);
                // Le moteur attend l'ordre OpenGL (lignes de bas en haut).
                for (int y = 0; y < h; ++y)
                    std::memcpy(&data.pixels[static_cast<size_t>(y) * w * 4],
                                &rgba[static_cast<size_t>(h - 1 - y) * w * 4], static_cast<size_t>(w) * 4);
                list.push_back(std::move(data));
            }
            return list;
        };

        ctx->last_result = Slic3r::GCodeProcessorResult();
        print.export_gcode(out_gcode, &ctx->last_result, thumbnails);
        ctx->has_result = true;

        if (FILE *f = std::fopen(out_gcode, "rb")) {
            std::fclose(f);
        } else {
            set_err(err_msg, err_len, "the core reported success but no G-code was written");
            return QSID_ERR_IO;
        }
        if (out_summary_json)
            *out_summary_json = dup_string(build_summary(print, ctx->last_result));
        return QSID_OK;
    } catch (const Slic3r::CanceledException &) {
        set_err(err_msg, err_len, "canceled");
        return QSID_ERR_CANCELED;
    } catch (const std::exception &e) {
        set_err(err_msg, err_len, e.what());
        return QSID_ERR_SLICE_FAILED;
    }
}

int qsid_gcode_moves(qsid_ctx *ctx, qsid_move **moves, size_t *count)
{
    QSID_REQUIRE_CTX(ctx);
    if (!moves || !count)
        return QSID_ERR_ARG;
    *moves = nullptr;
    *count = 0;
    if (!ctx->has_result)
        return QSID_OK;

    size_t keep = 0;
    auto wanted = [](Slic3r::EMoveType t) {
        return t == Slic3r::EMoveType::Extrude || t == Slic3r::EMoveType::Travel ||
               t == Slic3r::EMoveType::Wipe || t == Slic3r::EMoveType::Retract ||
               t == Slic3r::EMoveType::Unretract || t == Slic3r::EMoveType::Seam;
    };
    for (const auto &mv : ctx->last_result.moves)
        if (wanted(mv.type))
            ++keep;

    qsid_move *buf = static_cast<qsid_move *>(std::malloc(std::max<size_t>(keep, 1) * sizeof(qsid_move)));
    if (!buf)
        return QSID_ERR_ARG;
    size_t i = 0;
    for (const auto &mv : ctx->last_result.moves) {
        if (!wanted(mv.type))
            continue;
        qsid_move &o = buf[i++];
        o.x = mv.position.x(); o.y = mv.position.y(); o.z = mv.position.z();
        o.feedrate = mv.feedrate; o.width = mv.width; o.height = mv.height;
        o.fan_speed = mv.fan_speed; o.temperature = mv.temperature;
        o.time = mv.time[0]; o.e_delta = mv.delta_extruder;
        o.layer = mv.layer_id;
        o.type = static_cast<uint8_t>(mv.type);
        o.role = static_cast<uint8_t>(mv.extrusion_role);
        o.extruder = mv.extruder_id;
        o.reserved = 0;
    }
    *moves = buf;
    *count = keep;
    return QSID_OK;
}

void qsid_set_thumbnail_provider(qsid_ctx *ctx, qsid_thumbnail_cb cb, void *user)
{
    if (!ctx)
        return;
    ctx->thumbnail_cb = cb;
    ctx->thumbnail_user = user;
}

} // extern "C"
