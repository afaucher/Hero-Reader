#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "word_listener.h"

using namespace godot;

static void initialize_hero_listen(ModuleInitializationLevel level) {
  if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
  GDREGISTER_CLASS(WordListener);
}

static void uninitialize_hero_listen(ModuleInitializationLevel level) {}

extern "C" {
GDExtensionBool GDE_EXPORT hero_listen_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                            const GDExtensionClassLibraryPtr library,
                                            GDExtensionInitialization *init) {
  GDExtensionBinding::InitObject obj(get_proc_address, library, init);
  obj.register_initializer(initialize_hero_listen);
  obj.register_terminator(uninitialize_hero_listen);
  obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
  return obj.init();
}
}
