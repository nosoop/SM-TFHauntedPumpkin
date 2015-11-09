#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>

#pragma newdecls required

#define PLUGIN_VERSION "0.4.0"
public Plugin myinfo = {
    name = "[TF2] Haunted Pumpkins (Scream Fortress 7)",
    author = "nosoop",
    description = "Randomly gives a pumpkin the spirit of the Medic's little monster from the Scream Fortress 7 comic.",
    version = PLUGIN_VERSION,
    url = "https://github.com/nosoop"
}

// Sounds to precache
#define SOUND_PUMPKIN_BOMB_FMT "vo/halloween_merasmus/hall2015_pumpbomb_%02d.mp3"
int g_pumpkinBombSounds[] = { 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 14, 15 };
#define SOUND_PUMPKIN_BOMB_EXPLODE_FMT "vo/halloween_merasmus/hall2015_pumpbombboom_%02d.mp3"
int g_pumpkinBombExplodeSounds[] = { 1, 2, 3, 4, 5, 6, 7 };

// Particle effect added to the pumpkin.
char g_HauntedPumpkinParticleNames[][] = {
	"unusual_mystery_parent_green", // neutral
	"player_recent_teleport_red", // red
	"player_recent_teleport_blue" // blue
};

#define HAUNTED_PUMPKIN_TARGET_PREFIX "haunted_pumpkin"
#define HAUNTED_PARTICLE_TARGET "haunted_pumpkin_fx"

#define PUMPKIN_TALK_INTERVAL_MIN 3.0
#define PUMPKIN_TALK_INTERVAL_MAX 15.0

#define HAUNTED_PUMPKIN_MODEL "models/props_halloween/jackolantern_01.mdl"

// Identifies a specific pumpkin for the particle attachment
int g_nHauntedPumpkinsSpawned;

ConVar g_ConVarHauntingRate, g_ConVarAllowMultiple, g_ConVarHauntTeams;

public void OnPluginStart() {
	HookEvent("player_death", Event_PlayerDeath_HauntedPumpkin);
	
	CreateConVar("sm_hpumpkin_version", PLUGIN_VERSION, "Version of Haunted Pumpkins.", FCVAR_PLUGIN | FCVAR_NOTIFY | FCVAR_DONTRECORD);
	
	g_ConVarHauntingRate = CreateConVar("sm_hpumpkin_spawn_rate", "0.1", "Probability that a given pumpkin bomb will spawn haunted.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_ConVarAllowMultiple = CreateConVar("sm_hpumpkin_allow_multiple", "0", "Whether or not multiple haunted pumpkins are allowed to spawn.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_ConVarHauntTeams = CreateConVar("sm_hpumpkin_haunt_teams", "1", "Whether or not team-colored pumpkin bombs (e.g., from the Pumpkin MIRV spell) can be haunted.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	
	AutoExecConfig(true);
}

public void OnPluginEnd() {
	// Cleans up all particle effects (note that models remain)
	int particle = -1;
	char targetname[64];
	while ((particle = FindEntityByClassname(particle, "info_particle_system")) != -1) {
		GetEntPropString(particle, Prop_Data, "m_iName", targetname, sizeof(targetname));
		if (StrEqual(targetname, HAUNTED_PARTICLE_TARGET)) {
			AcceptEntityInput(particle, "Kill");
		}
	}
}

public void OnMapStart() {
	g_nHauntedPumpkinsSpawned = 0;
	
	// For some reason, we cannot use the native game sound precache method, so we'll just have to hardcode the cache.
	char gameSounds[PLATFORM_MAX_PATH];
	for (int i = 0; i < sizeof(g_pumpkinBombSounds); i++) {
		Format(gameSounds, sizeof(gameSounds), SOUND_PUMPKIN_BOMB_FMT, g_pumpkinBombSounds[i]);
		PrecacheSound(gameSounds);
	}
	for (int i = 0; i < sizeof(g_pumpkinBombExplodeSounds); i++) {
		Format(gameSounds, sizeof(gameSounds), SOUND_PUMPKIN_BOMB_EXPLODE_FMT, g_pumpkinBombExplodeSounds[i]);
		PrecacheSound(gameSounds);
	}
	
	PrecacheModel(HAUNTED_PUMPKIN_MODEL, true);
	
	// Rehaunt any existing haunted pumpkins in the event that the plugin was reloaded
	int pumpkin = -1;
	char targetname[64];
	while ((pumpkin = FindEntityByClassname(pumpkin, "tf_pumpkin_bomb")) != -1) {
		GetEntPropString(pumpkin, Prop_Data, "m_iName", targetname, sizeof(targetname));
		if (StrContains(targetname, HAUNTED_PUMPKIN_TARGET_PREFIX, false) > -1) {
			HauntPumpkin(pumpkin);
		}
	}
	if (g_nHauntedPumpkinsSpawned > 0) {
		LogMessage("%d pumpkin(s) are now haunted.", g_nHauntedPumpkinsSpawned);
	}
}

public void OnEntityCreated(int entity, const char[] classname) {
	if (StrEqual(classname, "tf_pumpkin_bomb", false)) {
		SDKHook(entity, SDKHook_SpawnPost, SDKHook_SpawnPost_HauntedPumpkin);
	}
}

/**
 * Prepares to attempt pumpkin transformation when the entity is spawned.
 */
public void SDKHook_SpawnPost_HauntedPumpkin(int pumpkin) {
	/**
	 * The SpawnPost hook might fire before the map is fully loaded, but the following error
	 * will be thrown if we try to spawn an entity (such as the particle effect) during that time:
	 * "Cannot create new entity when no map is running"
	 * 
	 * We'll just attempt to haunt pumpkins once there's at least one player in-game.
	 */
	if (GameRules_GetRoundState() > RoundState_Pregame) {
		CheckSpawnAsHauntedPumpkin(pumpkin);
	}
}

/**
 * Determine whether or not a pumpkin bomb is allowed to be haunted.
 */
void CheckSpawnAsHauntedPumpkin(int pumpkin) {
	if (GetRandomFloat() < g_ConVarHauntingRate.FloatValue
			&& (g_ConVarHauntTeams.BoolValue || GetPumpkinTeam(pumpkin) == TFTeam_Unassigned)
			&& (g_ConVarAllowMultiple.BoolValue || !DoesHauntedPumpkinExist()) ) {
		HauntPumpkin(pumpkin);
	}
}

/**
 * Returns true if at least one pumpkin bomb with a target name matching that of the plugin's haunted pumpkin prefix exists.
 */
bool DoesHauntedPumpkinExist() {
	int pumpkin = -1;
	char targetname[64];
	while ((pumpkin = FindEntityByClassname(pumpkin, "tf_pumpkin_bomb")) != -1) {
		GetEntPropString(pumpkin, Prop_Data, "m_iName", targetname, sizeof(targetname));
		if (StrContains(targetname, HAUNTED_PUMPKIN_TARGET_PREFIX, false) > -1) {
			return true;
		}
	}
	return false;
}

/**
 * Turns a pumpkin bomb into a haunted pumpkin bomb (model change, particle effect, sound timer, damage hook).
 */
void HauntPumpkin(int pumpkin) {
	char pumpkinTarget[64];
	Format(pumpkinTarget, sizeof(pumpkinTarget), HAUNTED_PUMPKIN_TARGET_PREFIX ... "_%d", g_nHauntedPumpkinsSpawned++);
	
	TFTeam pumpkinTeam = GetPumpkinTeam(pumpkin);
	
	int iParticleEffect = 0;
	switch(pumpkinTeam) {
		case TFTeam_Red: { iParticleEffect = 1; }
		case TFTeam_Blue: { iParticleEffect = 2; }
	}
	
	int particle = CreateParticle(g_HauntedPumpkinParticleNames[iParticleEffect]);
	if (IsValidEdict(particle)) {
		DispatchKeyValue(pumpkin, "targetname", pumpkinTarget);
		DispatchKeyValue(particle, "targetname", HAUNTED_PARTICLE_TARGET);
		
		float particleOrigin[3];
		GetEntPropVector(pumpkin, Prop_Send, "m_vecOrigin", particleOrigin);
		
		/**
		 * Neutral pumpkin bombs' particle effects applies over the top of its head;
		 * team colored ones are on the ground.
		 */
		if (pumpkinTeam == TFTeam_Unassigned) {
			particleOrigin[2] += 12.0;
		}
		TeleportEntity(particle, particleOrigin, NULL_VECTOR, NULL_VECTOR);
		
		DispatchKeyValue(particle, "parentname", pumpkinTarget);
		
		SetVariantString(pumpkinTarget);
		AcceptEntityInput(particle, "SetParent", particle, particle, 0);
		
		SDKHook(pumpkin, SDKHook_OnTakeDamage, SDKHook_OnHauntedPumpkinDestroyed);
		PreparePumpkinTalkTimer(pumpkin);
		
		SetEntityModel(pumpkin, HAUNTED_PUMPKIN_MODEL);
		
		// MIRV pumpkin bombs are slightly smaller than their standard counterparts.
		float flModelScale = pumpkinTeam == TFTeam_Unassigned ? 0.55 : (0.9 * 0.55);
		SetEntPropFloat(pumpkin, Prop_Data, "m_flModelScale", flModelScale);
		
		AcceptEntityInput(pumpkin, "DisableShadow");
	}
}

/**
 * Returns the pumpkin spawner's team.
 */
TFTeam GetPumpkinTeam(int pumpkin) {
	// TODO is there a better way to get the pumpkin's team?  iTeamNum is 0, hOwnerEntity doesn't exist...
	switch (GetEntProp(pumpkin, Prop_Data, "m_nSkin")) {
		case 1: { return TFTeam_Red; }
		case 2: { return TFTeam_Blue; }
	}
	return TFTeam_Unassigned;
}

int CreateParticle(const char[] effectName) {
	int particle = CreateEntityByName("info_particle_system");
	
	if (IsValidEdict(particle)) {
		DispatchKeyValue(particle, "effect_name", effectName);
		DispatchSpawn(particle);
		
		ActivateEntity(particle);
		AcceptEntityInput(particle, "start");
	}
	return particle;
}

/**
 * Play the haunted pumpkin explosion sound when hit.
 */
public Action SDKHook_OnHauntedPumpkinDestroyed(int pumpkin, int &attacker, int &inflictor, float &damage, int &damagetype) {
	SDKUnhook(pumpkin, SDKHook_OnTakeDamage, SDKHook_OnHauntedPumpkinDestroyed);
	
	char sample[PLATFORM_MAX_PATH];
	GetGameSoundSample("sf15.Pumpkin.Bomb.Explode", sample, sizeof(sample));
	EmitSoundToAll(sample, pumpkin, _, SNDLEVEL_GUNFIRE);
	EmitSoundToClient(attacker, sample);
}

/**
 * Sets a timer for the next haunted pumpkin voice line.
 * The data timer validates the pumpkin according to targetname.
 */
Handle PreparePumpkinTalkTimer(int pumpkin) {
	float delay = GetRandomFloat(PUMPKIN_TALK_INTERVAL_MIN, PUMPKIN_TALK_INTERVAL_MAX);
	
	char targetname[64];
	GetEntPropString(pumpkin, Prop_Data, "m_iName", targetname, sizeof(targetname));
	
	Handle datapack;
	Handle timer = CreateDataTimer(delay, Timer_PumpkinTalk, datapack, TIMER_FLAG_NO_MAPCHANGE);
	
	WritePackCell(datapack, pumpkin);
	WritePackString(datapack, targetname);
	
	return timer;
}

public Action Timer_PumpkinTalk(Handle timer, any datapack) {
	ResetPack(datapack);
	int pumpkin = view_as<int>(ReadPackCell(datapack));
	
	char packedname[64];
	ReadPackString(datapack, packedname, sizeof(packedname));
	
	if (IsValidEntity(pumpkin)) {
		char classname[64], targetname[64];
		GetEntPropString(pumpkin, Prop_Data, "m_iName", targetname, sizeof(targetname));
		
		GetEntityClassname(pumpkin, classname, sizeof(classname));
		if (StrEqual(classname, "tf_pumpkin_bomb", false) && StrEqual(packedname, targetname, false)) {
			char sample[PLATFORM_MAX_PATH];
			
			GetGameSoundSample("sf15.Pumpkin.Bomb", sample, sizeof(sample));
			EmitSoundToAll(sample, pumpkin, _, SNDLEVEL_GUNFIRE);
			
			PreparePumpkinTalkTimer(pumpkin);
		}
	}
}

public Action Event_PlayerDeath_HauntedPumpkin(Handle event, const char[] name, bool dontBroadcast) {
	int inflictor = GetEventInt(event, "inflictor_entindex");
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if (IsValidEntity(inflictor)) {
		char classname[64];
		GetEntityClassname(inflictor, classname, sizeof(classname));
		
		if (StrEqual(classname, "tf_pumpkin_bomb", false)) {
			char targetname[64];
			GetEntPropString(inflictor, Prop_Data, "m_iName", targetname, sizeof(targetname));
			
			if (StrContains(targetname, HAUNTED_PUMPKIN_TARGET_PREFIX, false) > -1) {
				// TODO attempt to match voice line with damage event?
			}
		}
	}
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	if (GetEngineVersion() != Engine_TF2) {
		Format(error, err_max, "This plug-in only works for Team Fortress 2.");
		return APLRes_Failure;
	}
	return APLRes_Success;
}

/**
 * Get the sample for a game sound, throwing the rest of the parameters out.
 * Returns true if the sound was successfully retrieved, false if not found.
 */
bool GetGameSoundSample(const char[] gameSound, char[] sample, int maxlength) {
	int channel, soundLevel, pitch;
	float volume;
	
	return GetGameSoundParams(gameSound, channel, soundLevel, volume, pitch, sample, maxlength);
}