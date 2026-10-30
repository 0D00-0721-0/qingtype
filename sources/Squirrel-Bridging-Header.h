//
//  Use this file to import your target's public headers that you would like to
//  expose to Swift.
//

#import <rime_api_stdbool.h>
#import <rime/key_table.h>

// The levers module exports the integer-Bool ABI even when the core API uses
// stdbool. Import its actual ABI rather than casting function return types.
#undef RIME_FLAVORED
#define RIME_FLAVORED(name) name
#undef Bool
#define Bool int
#import <rime_levers_api.h>

static inline RimeLeversApi *qingtype_levers_api(RimeApi_stdbool *api) {
  RimeModule *module = api->find_module("levers");
  return module && module->get_api ? (RimeLeversApi *)module->get_api() : NULL;
}
