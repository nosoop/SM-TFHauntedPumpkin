#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>

#pragma newdecls required

#define PLUGIN_VERSION "0.4.5-custom-model"
public Plugin myinfo = {
    name = "[TF2] Haunted Pumpkins (Scream Fortress 7)",
    author = "nosoop",
    description = "Randomly gives a pumpkin the spirit of the Medic's little monster from the Scream Fortress 7 comic.",
    version = PLUGIN_VERSION,
    url = "https://github.com/nosoop/SM-TFHauntedPumpkin"
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

#define HAUNTED_PUMPKIN_TARGET "haunted_pumpkin"
#define HAUNTED_PARTICLE_TARGET "haunted_pumpkin_fx"

#define PUMPKIN_TALK_INTERVAL_MIN 3.0
#define PUMPKIN_TALK_INTERVAL_MAX 15.0

#define HAUNTED_PUMPKIN_MODEL "models/props_halloween/jackolantern_01"

char g_PumpkinModel[PLATFORM_MAX_PATH];

ConVar g_ConVarHauntingRate, g_ConVarAllowMultiple, g_ConVarHauntTeams, g_ConVarCustomModel;

public void OnPluginStart() {
	HookEvent("player_death", Event_PlayerDeath_HauntedPumpkin);
	
	CreateConVar("sm_hpumpkin_version", PLUGIN_VERSION, "Version of Haunted Pumpkins.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	
	g_ConVarHauntingRate = CreateConVar("sm_hpumpkin_spawn_rate", "0.1", "Probability that a given pumpkin bomb will spawn haunted.", _, true, 0.0, true, 1.0);
	g_ConVarAllowMultiple = CreateConVar("sm_hpumpkin_allow_multiple", "0", "Whether or not multiple haunted pumpkins are allowed to spawn.", _, true, 0.0, true, 1.0);
	g_ConVarHauntTeams = CreateConVar("sm_hpumpkin_haunt_teams", "1", "Whether or not team-colored pumpkin bombs (e.g., from the Pumpkin MIRV spell) can be haunted.", _, true, 0.0, true, 1.0);
	g_ConVarCustomModel = CreateConVar("sm_hpumpkin_model", HAUNTED_PUMPKIN_MODEL, "Model applied to the pumpkin bomb (without the .mdl extension).  Takes effect after configurations are reloaded (after map change).");
	
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
	int nRehauntedPumpkins = 0;
	
	// For some reason, we cannot use the native game sound precache method (PrecacheScriptSound),
	// so we'll just have to use hardcoded sound paths.
	char gameSounds[PLATFORM_MAX_PATH];
	for (int i = 0; i < sizeof(g_pumpkinBombSounds); i++) {
		Format(gameSounds, sizeof(gameSounds), SOUND_PUMPKIN_BOMB_FMT, g_pumpkinBombSounds[i]);
		PrecacheSound(gameSounds);
	}
	for (int i = 0; i < sizeof(g_pumpkinBombExplodeSounds); i++) {
		Format(gameSounds, sizeof(gameSounds), SOUND_PUMPKIN_BOMB_EXPLODE_FMT, g_pumpkinBombExplodeSounds[i]);
		PrecacheSound(gameSounds);
	}
	
	// Rehaunt any existing haunted pumpkins in the event that the plugin was reloaded
	int pumpkin = -1;
	char targetname[64];
	while ((pumpkin = FindEntityByClassname(pumpkin, "tf_pumpkin_bomb")) != -1) {
		GetEntPropString(pumpkin, Prop_Data, "m_iName", targetname, sizeof(targetname));
		if (StrEqual(targetname, HAUNTED_PUMPKIN_TARGET)) {
			HauntPumpkin(pumpkin);
			nRehauntedPumpkins++;
		}
	}
	
	if (nRehauntedPumpkins) {
		LogMessage("%d pumpkin(s) are now haunted.", nRehauntedPumpkins);
	}
}

public void OnConfigsExecuted() {
	char baseName[PLATFORM_MAX_PATH], downloadFile[PLATFORM_MAX_PATH];
	g_ConVarCustomModel.GetString(baseName, sizeof(baseName));
	
	Format(downloadFile, sizeof(downloadFile), "%s%s", baseName, ".dx80.vtx");
	AddFileToDownloadsTable(downloadFile);
	
	Format(downloadFile, sizeof(downloadFile), "%s%s", baseName, ".dx90.vtx");
	AddFileToDownloadsTable(downloadFile);
	
	Format(downloadFile, sizeof(downloadFile), "%s%s", baseName, ".sw.vtx");
	AddFileToDownloadsTable(downloadFile);
	
	Format(downloadFile, sizeof(downloadFile), "%s%s", baseName, ".phy");
	AddFileToDownloadsTable(downloadFile);
	
	Format(downloadFile, sizeof(downloadFile), "%s%s", baseName, ".vvd");
	AddFileToDownloadsTable(downloadFile);
	
	Format(downloadFile, sizeof(downloadFile), "%s%s", baseName, ".mdl");
	AddFileToDownloadsTable(downloadFile);
	
	strcopy(g_PumpkinModel, sizeof(g_PumpkinModel), downloadFile);
	PrecacheModel(g_PumpkinModel, true);
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
		if (StrEqual(targetname, HAUNTED_PUMPKIN_TARGET)) {
			return true;
		}
	}
	return false;
}

/**
 * Turns a pumpkin bomb into a haunted pumpkin bomb (model change, particle effect, sound timer, damage hook).
 */
void HauntPumpkin(int pumpkin) {
	TFTeam pumpkinTeam = GetPumpkinTeam(pumpkin);
	
	int iParticleEffect = 0;
	switch (pumpkinTeam) {
		case TFTeam_Red: { iParticleEffect = 1; }
		case TFTeam_Blue: { iParticleEffect = 2; }
	}
	
	int particle = CreateParticle(g_HauntedPumpkinParticleNames[iParticleEffect]);
	if (IsValidEdict(particle)) {
		DispatchKeyValue(pumpkin, "targetname", HAUNTED_PUMPKIN_TARGET);
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
		
		SetVariantString("!activator");
		AcceptEntityInput(particle, "SetParent", pumpkin, particle, 0);
		
		SDKHook(pumpkin, SDKHook_OnTakeDamagePost, SDKHook_OnHauntedPumpkinDestroyed);
		PreparePumpkinTalkTimer(pumpkin);
		
		SetEntityModel(pumpkin, g_PumpkinModel);
		
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
public void SDKHook_OnHauntedPumpkinDestroyed(int pumpkin, int attacker, int inflictor,
		float damage, int damagetype) {
	char sample[PLATFORM_MAX_PATH];
	GetGameSoundSample("sf15.Pumpkin.Bomb.Explode", sample, sizeof(sample));
	EmitSoundToAll(sample, pumpkin, _, SNDLEVEL_GUNFIRE);
	
	if (attacker && attacker <= MaxClients && IsClientInGame(attacker)) {
		EmitSoundToClient(attacker, sample);
	}
}

/**
 * Sets a timer for the next voice line to come from a specific pumpkin.
 */
void PreparePumpkinTalkTimer(int pumpkin) {
	float delay = GetRandomFloat(PUMPKIN_TALK_INTERVAL_MIN, PUMPKIN_TALK_INTERVAL_MAX);
	
	CreateTimer(delay, Timer_PumpkinTalk, EntIndexToEntRef(pumpkin), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PumpkinTalk(Handle timer, int pumpkinref) {
	int pumpkin = EntRefToEntIndex(pumpkinref);
	
	if (IsValidEntity(pumpkin)) {
		char sample[PLATFORM_MAX_PATH];
		
		GetGameSoundSample("sf15.Pumpkin.Bomb", sample, sizeof(sample));
		EmitSoundToAll(sample, pumpkin, _, SNDLEVEL_GUNFIRE);
		
		PreparePumpkinTalkTimer(pumpkin);
	}
	return Plugin_Handled;
}

public void Event_PlayerDeath_HauntedPumpkin(Event event, const char[] name, bool dontBroadcast) {
	int inflictor = event.GetInt("inflictor_entindex");
	int victim = GetClientOfUserId(event.GetInt("userid"));
	
	if (IsValidEntity(inflictor)) {
		char classname[64];
		GetEntityClassname(inflictor, classname, sizeof(classname));
		
		if (StrEqual(classname, "tf_pumpkin_bomb", false)) {
			char targetname[64];
			GetEntPropString(inflictor, Prop_Data, "m_iName", targetname, sizeof(targetname));
			
			if (StrEqual(targetname, HAUNTED_PUMPKIN_TARGET)) {
				// TODO attempt to match voice line with damage event?
			}
		}
	}
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	if (GetEngineVersion() != Engine_TF2) {
		strcopy(error, err_max, "This plug-in only works for Team Fortress 2.");
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