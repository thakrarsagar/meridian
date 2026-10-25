use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    ffi::{CStr, CString, c_char},
};

const CATALOGUE_URL: &str = "https://api.nordvpn.com/v1/servers/countries?filters%5Bservers_technologies%5D%5Bidentifier%5D=ikev2";

#[derive(Clone, Deserialize, Serialize)]
struct Location {
    country_id: u64,
    city_id: Option<u64>,
    country: String,
    city: Option<String>,
    single_city: Option<String>,
    code: String,
}

#[derive(Deserialize)]
struct Country {
    id: u64,
    name: String,
    code: String,
    cities: Vec<City>,
}

#[derive(Deserialize)]
struct City {
    id: u64,
    name: String,
}

#[derive(Default, Serialize)]
struct State {
    generation: u64,
    phase: Phase,
    requested: Option<Location>,
    connected: Option<Location>,
    hostname: Option<String>,
    wanted: bool,
    established: bool,
    error: Option<String>,
}

#[derive(Default, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    #[default]
    Disconnected,
    Resolving,
    Connecting,
    Connected,
    Reconnecting,
    Disconnecting,
    Failed,
}

#[derive(Default)]
pub struct Core {
    locations: Vec<Location>,
    state: State,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Command {
    Catalogue {
        payload: Value,
    },
    Search {
        query: String,
    },
    Connect {
        country_id: u64,
        city_id: Option<u64>,
    },
    Recommendation {
        generation: u64,
        payload: Value,
    },
    Status {
        generation: u64,
        status: u32,
    },
    Failure {
        generation: u64,
        message: String,
    },
    Disconnect,
    Resume,
    Snapshot,
}

fn valid_name(s: &str) -> bool {
    !s.trim().is_empty() && s.len() <= 160 && !s.chars().any(char::is_control)
}

fn valid_hostname(s: &str) -> bool {
    let Some(label) = s.strip_suffix(".nordvpn.com") else {
        return false;
    };
    !label.is_empty()
        && label.len() <= 63
        && !label.starts_with('-')
        && !label.ends_with('-')
        && label
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

impl Core {
    fn run(&mut self, command: Command) -> Result<Value, String> {
        let mut extra = json!({});
        match command {
            Command::Catalogue { payload } => {
                let countries: Vec<Country> = serde_json::from_value(payload)
                    .map_err(|_| "Nord returned an unreadable location list.")?;
                if countries.is_empty() || countries.len() > 300 {
                    return Err("Nord returned an invalid country count.".into());
                }
                let mut locations = Vec::new();
                let mut ids = HashSet::new();
                for country in countries {
                    if country.id == 0
                        || !ids.insert((country.id, None))
                        || !valid_name(&country.name)
                        || country.code.len() != 2
                        || !country.code.bytes().all(|c| c.is_ascii_uppercase())
                        || country.cities.len() > 500
                    {
                        return Err("Nord returned an invalid country.".into());
                    }
                    let location = Location {
                        country_id: country.id,
                        city_id: None,
                        country: country.name,
                        city: None,
                        single_city: (country.cities.len() == 1)
                            .then(|| country.cities[0].name.clone()),
                        code: country.code,
                    };
                    locations.push(location.clone());
                    for city in country.cities {
                        if city.id == 0
                            || !valid_name(&city.name)
                            || !ids.insert((country.id, Some(city.id)))
                        {
                            return Err("Nord returned an invalid city.".into());
                        }
                        if location.single_city.is_none() {
                            locations.push(Location {
                                city_id: Some(city.id),
                                city: Some(city.name),
                                ..location.clone()
                            });
                        }
                    }
                }
                locations.sort_by(|a, b| a.country.cmp(&b.country).then(a.city.cmp(&b.city)));
                self.locations = locations;
                extra["count"] = json!(self.locations.len());
            }
            Command::Search { query } => {
                if query.len() > 256 {
                    return Err("Search is too long.".into());
                }
                let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
                extra["locations"] = json!(
                    self.locations
                        .iter()
                        .filter(|l| {
                            let text = format!(
                                "{} {} {}",
                                l.country,
                                l.city.as_deref().or(l.single_city.as_deref()).unwrap_or(""),
                                l.code
                            )
                            .to_lowercase();
                            words.iter().all(|w| text.contains(w))
                        })
                        .collect::<Vec<_>>()
                );
            }
            Command::Connect {
                country_id,
                city_id,
            } => {
                let location = self
                    .locations
                    .iter()
                    .find(|l| l.country_id == country_id && l.city_id == city_id)
                    .ok_or("Choose a location from the current list.")?
                    .clone();
                self.state.generation += 1;
                self.state.requested = Some(location);
                self.state.wanted = true;
                self.state.established = false;
                self.state.phase = Phase::Resolving;
                self.state.error = None;
                let mut url = format!(
                    "https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=ikev2&filters%5Bcountry_id%5D={country_id}&limit=1"
                );
                if let Some(city) = city_id {
                    url.push_str(&format!("&filters%5Bcity_id%5D={city}"));
                }
                extra["url"] = json!(url);
            }
            Command::Recommendation {
                generation,
                payload,
            } => {
                if generation != self.state.generation
                    || !self.state.wanted
                    || self.state.phase != Phase::Resolving
                {
                    extra["ignored"] = json!(true);
                } else {
                    let requested = self
                        .state
                        .requested
                        .as_ref()
                        .ok_or("No location is selected.")?;
                    let servers = payload
                        .as_array()
                        .ok_or("Nord returned an unreadable recommendation.")?;
                    let server = servers
                        .iter()
                        .find(|s| {
                            s["status"] == "online"
                                && s["hostname"].as_str().is_some_and(valid_hostname)
                                && s["technologies"].as_array().is_some_and(|ts| {
                                    ts.iter().any(|t| {
                                        t["identifier"] == "ikev2"
                                            && t["pivot"]["status"] == "online"
                                    })
                                })
                                && s["locations"].as_array().is_some_and(|ls| {
                                    ls.iter().any(|l| {
                                        l["country"]["id"].as_u64() == Some(requested.country_id)
                                            && requested.city_id.is_none_or(|c| {
                                                l["country"]["city"]["id"].as_u64() == Some(c)
                                            })
                                    })
                                })
                        })
                        .ok_or(
                            "No online IKEv2 server is available for this location. Try again.",
                        )?;
                    self.state.hostname = Some(server["hostname"].as_str().unwrap().to_owned());
                    self.state.connected = None;
                    self.state.phase = Phase::Connecting;
                    extra["effect"] = json!("connect");
                }
            }
            Command::Status { generation, status } => {
                if generation != self.state.generation {
                    extra["ignored"] = json!(true);
                } else {
                    match status {
                        3 if self.state.wanted && self.state.phase != Phase::Resolving => {
                            self.state.phase = Phase::Connected;
                            self.state.connected = self.state.requested.clone();
                            self.state.established = true;
                            self.state.error = None;
                        }
                        3 if !self.state.wanted => self.state.phase = Phase::Connected,
                        2 | 4 if self.state.wanted && self.state.phase != Phase::Resolving => {
                            self.state.phase = if self.state.established {
                                Phase::Reconnecting
                            } else {
                                Phase::Connecting
                            };
                        }
                        0 | 1 => {
                            self.state.connected = None;
                            if !self.state.wanted {
                                self.state.phase = Phase::Disconnected;
                            } else if self.state.phase != Phase::Resolving {
                                if self.state.established {
                                    self.state.phase = Phase::Reconnecting;
                                    extra["effect"] = json!("resume_later");
                                } else {
                                    self.state.phase = Phase::Failed;
                                    if self.state.error.is_none() {
                                        self.state.error = Some("Nord did not connect. Check service credentials and the Nord certificate, then Retry.".into());
                                    }
                                }
                            }
                        }
                        5 if self.state.phase != Phase::Resolving => {
                            self.state.phase = Phase::Disconnecting
                        }
                        _ => {}
                    }
                }
            }
            Command::Failure {
                generation,
                message,
            } => {
                if generation == self.state.generation {
                    self.state.phase = if self.state.wanted && self.state.established {
                        Phase::Reconnecting
                    } else {
                        Phase::Failed
                    };
                    self.state.error = Some(message.chars().take(400).collect());
                    if self.state.phase == Phase::Reconnecting {
                        extra["effect"] = json!("resume_later");
                    }
                }
            }
            Command::Disconnect => {
                self.state.generation += 1;
                self.state.wanted = false;
                self.state.established = false;
                self.state.error = None;
                self.state.phase = Phase::Disconnecting;
                extra["effect"] = json!("disconnect");
            }
            Command::Resume => {
                if self.state.wanted
                    && self.state.established
                    && self.state.phase == Phase::Reconnecting
                {
                    self.state.generation += 1;
                    self.state.phase = Phase::Reconnecting;
                    extra["effect"] = json!("connect");
                }
            }
            Command::Snapshot => {
                extra["catalogue_url"] = json!(CATALOGUE_URL);
            }
        }
        extra["ok"] = json!(true);
        extra["state"] = serde_json::to_value(&self.state).unwrap();
        Ok(extra)
    }

    fn dispatch(&mut self, input: &str) -> Value {
        let result = serde_json::from_str::<Command>(input)
            .map_err(|_| "Invalid core command.".to_owned())
            .and_then(|c| self.run(c));
        result.unwrap_or_else(|e| json!({"ok":false,"error":e,"state":self.state}))
    }
}

// The host serializes access on its main thread; returned strings belong to the caller.
#[unsafe(no_mangle)]
pub extern "C" fn nord_core_new() -> *mut Core {
    Box::into_raw(Box::new(Core::default()))
}

/// # Safety
/// `core` must be a live handle; `input` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nord_core_call(core: *mut Core, input: *const c_char) -> *mut c_char {
    if core.is_null() || input.is_null() {
        return std::ptr::null_mut();
    }
    let result = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) if s.len() <= 1_048_576 => unsafe { &mut *core }.dispatch(s),
        _ => json!({"ok":false,"error":"Invalid or oversized core input."}),
    };
    CString::new(result.to_string()).unwrap().into_raw()
}

/// # Safety
/// Free exactly once, using a handle returned by `nord_core_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nord_core_free(core: *mut Core) {
    if !core.is_null() {
        drop(unsafe { Box::from_raw(core) });
    }
}

/// # Safety
/// Free exactly once, using a string returned by `nord_core_call`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nord_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn core() -> Core {
        let mut c = Core::default();
        assert!(c.dispatch(r#"{"op":"catalogue","payload":[{"id":81,"name":"Germany","code":"DE","cities":[{"id":1,"name":"Berlin"},{"id":2,"name":"Munich"}]}]}"#)["ok"] == true);
        c
    }
    fn server() -> Value {
        json!([{"hostname":"de123.nordvpn.com","status":"online","technologies":[{"identifier":"ikev2","pivot":{"status":"online"}}],"locations":[{"country":{"id":81,"city":{"id":1}}}]}])
    }
    #[test]
    fn catalogue_search_and_eligible_server() {
        let mut c = core();
        assert_eq!(
            c.run(Command::Search {
                query: "ber de".into()
            })
            .unwrap()["locations"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let r = c
            .run(Command::Connect {
                country_id: 81,
                city_id: Some(1),
            })
            .unwrap();
        assert!(r["url"].as_str().unwrap().contains("city_id%5D=1"));
        assert_eq!(
            c.run(Command::Recommendation {
                generation: 1,
                payload: server()
            })
            .unwrap()["effect"],
            "connect"
        );
        c.run(Command::Status {
            generation: 1,
            status: 3,
        })
        .unwrap();
        assert!(c.state.established);
        c.run(Command::Status {
            generation: 1,
            status: 5,
        })
        .unwrap();
        assert_eq!(
            c.run(Command::Status {
                generation: 1,
                status: 1
            })
            .unwrap()["effect"],
            "resume_later"
        );
        assert_eq!(c.run(Command::Resume).unwrap()["effect"], "connect");
        assert_eq!(
            c.run(Command::Failure {
                generation: 2,
                message: "Network unavailable".into()
            })
            .unwrap()["effect"],
            "resume_later"
        );
        c.run(Command::Disconnect).unwrap();
        assert!(c.run(Command::Resume).unwrap().get("effect").is_none());
    }
    #[test]
    fn failed_switch_and_stale_callbacks_cannot_connect() {
        let mut c = core();
        c.run(Command::Connect {
            country_id: 81,
            city_id: None,
        })
        .unwrap();
        let mut bad = server();
        bad[0]["hostname"] = json!("de123.nordvpn.com.evil.test");
        assert!(
            c.run(Command::Recommendation {
                generation: 1,
                payload: bad
            })
            .is_err()
        );
        let mut wrong_city = server();
        wrong_city[0]["locations"][0]["country"]["city"]["id"] = json!(99);
        c.run(Command::Connect {
            country_id: 81,
            city_id: Some(1),
        })
        .unwrap();
        assert!(
            c.run(Command::Recommendation {
                generation: 2,
                payload: wrong_city
            })
            .is_err()
        );
        let mut offline = server();
        offline[0]["technologies"][0]["pivot"]["status"] = json!("offline");
        assert!(
            c.run(Command::Recommendation {
                generation: 2,
                payload: offline
            })
            .is_err()
        );
        c.run(Command::Failure {
            generation: 2,
            message: "Failed".into(),
        })
        .unwrap();
        assert_eq!(c.state.requested.as_ref().unwrap().city_id, Some(1));
        c.run(Command::Status {
            generation: 2,
            status: 1,
        })
        .unwrap();
        assert_eq!(c.state.error.as_deref(), Some("Failed"));
        assert_eq!(
            c.run(Command::Recommendation {
                generation: 2,
                payload: server()
            })
            .unwrap()["ignored"],
            true
        );
        c.run(Command::Disconnect).unwrap();
        assert_eq!(
            c.run(Command::Status {
                generation: 2,
                status: 3
            })
            .unwrap()["ignored"],
            true
        );
        assert!(!c.state.wanted);
    }
    #[test]
    fn single_city_countries_have_one_searchable_option() {
        let mut c = core();
        c.run(Command::Catalogue {
            payload: json!([
                {"id":1,"name":"Singapore","code":"SG","cities":[{"id":10,"name":"Singapore"}]},
                {"id":2,"name":"Ireland","code":"IE","cities":[{"id":20,"name":"Dublin"}]},
                {"id":3,"name":"United Kingdom","code":"GB","cities":[{"id":30,"name":"London"},{"id":31,"name":"Manchester"}]}
            ]),
        })
        .unwrap();
        let singapore = c
            .run(Command::Search {
                query: "Singapore".into(),
            })
            .unwrap();
        assert_eq!(singapore["locations"].as_array().unwrap().len(), 1);
        assert!(singapore["locations"][0]["city_id"].is_null());
        assert_eq!(singapore["locations"][0]["single_city"], "Singapore");
        let dublin = c
            .run(Command::Search {
                query: "dub ie".into(),
            })
            .unwrap();
        assert_eq!(dublin["locations"].as_array().unwrap().len(), 1);
        assert_eq!(dublin["locations"][0]["country"], "Ireland");
        assert!(dublin["locations"][0]["city_id"].is_null());
        let uk = c
            .run(Command::Search {
                query: "United Kingdom".into(),
            })
            .unwrap();
        let choices = uk["locations"].as_array().unwrap();
        assert_eq!(choices.len(), 3);
        assert!(choices[0]["city_id"].is_null());
        assert_eq!(choices[1]["city"], "London");
        assert_eq!(choices[2]["city"], "Manchester");
        let request = c
            .run(Command::Connect {
                country_id: 2,
                city_id: None,
            })
            .unwrap();
        assert!(!request["url"].as_str().unwrap().contains("city_id"));
    }
    #[test]
    fn invalid_refresh_preserves_catalogue() {
        let mut c = core();
        assert!(c.run(Command::Catalogue { payload: json!([]) }).is_err());
        assert!(c.run(Command::Catalogue {
            payload: json!([{"id":1,"name":"Ireland","code":"IE","cities":[{"id":20,"name":"\n"}]}])
        }).is_err());
        assert_eq!(c.locations.len(), 3);
    }
}
