--intykat 2024
--https://devforum.roblox.com/t/audiograph-a-module-that-manages-robloxs-new-audio-api-for-you/2872014
local SoundService = game:GetService("SoundService")

export type AudioProducerInstance = AudioPlayer | AudioDeviceInput | AudioListener
export type AudioModifierInstance = AudioCompressor | AudioFader | AudioDistortion | AudioEcho | AudioEqualizer | AudioFlanger | AudioPitchShifter | AudioReverb | AudioChorus
export type AudioConsumerInstance = AudioEmitter | AudioAnalyzer | AudioDeviceOutput

local Audio = {
	Graphs = {}
}

local AudioGraph = {}
AudioGraph.__index = AudioGraph

function Audio.NewGraph(Producer: AudioProducerInstance & Instance): typeof(AudioGraph)
	
	local self = setmetatable({
		ProducerInstance = Producer,

		Modifiers = {},
		ModifierRemoving = Instance.new("BindableEvent"),
		ModifierAdded = Instance.new("BindableEvent"),

		Consumers = {},
		ConsumerRemoved = Instance.new("BindableEvent"),
		ConsumerAdded = Instance.new("BindableEvent"),

		Wires = {},
		SidechainWires = {},
		Branches = {},
		BranchingFrom = nil,
	}, AudioGraph)

	if not Producer.Parent then
		Producer.Parent = game:GetService("SoundService")
	end

	local ModifiersFolder = Producer:FindFirstChild("Modifiers") or Instance.new("Folder", Producer)
	ModifiersFolder.Name = "Modifiers"
	local ConsumersFolder = Producer:FindFirstChild("Consumers") or Instance.new("Folder", Producer)
	ConsumersFolder.Name = "Consumers"

	local VolumeInstance = Instance.new("AudioFader")
	VolumeInstance.Name = "_MainVolume"
	self:ConnectModifier(VolumeInstance)

	table.insert(Audio.Graphs, self)
	
	self.ModifierRemoving.Event:Connect(function(Modifier)
		for _, Branch in pairs(self.Branches) do
			if Modifier == Branch.ProducerInstance then
				Branch:Cleanup(Branch.DestroyAll)
				
				table.remove(self.Branches, table.find(self.Branches, Branch))
			end
		end
	end)
	
	Producer.Destroying:Connect(function()
		table.remove(Audio.Graphs, table.find(Audio.Graphs, Producer))
	end)
	
	return self
end

function AudioGraph:CreateModifier(ModifierName: "Compressor" | "Fader" | "Distortion" | "Echo" | "Equalizer" | "Flanger" | "PitchShifter" | "Reverb" | "Chorus", Properties: {}): AudioModifierInstance
	local AudioInstance
	local sucess, result = pcall(function()
		AudioInstance = Instance.new(`Audio{ModifierName}`)
		
		if not Properties then return end
		for property, value in pairs(Properties) do
			AudioInstance[property] = value
		end
	end)
	if not sucess then
		warn(`Could not create instance "Audio{ModifierName}"!\n`, result)
		return
	end
	
	self:ConnectModifier(AudioInstance)
	return AudioInstance
end

function AudioGraph:SetVolume(Volume: number)
	self:GetAudioInstance("_MainVolume").Volume = Volume
	
	return self
end

function AudioGraph:ConnectModifier(Modifier: AudioModifierInstance & Instance): typeof(AudioGraph)
	if not Modifier.Parent then 
		Modifier.Parent = self.ProducerInstance.Modifiers
	end

	local LastModifier = #self.Modifiers > 0 and self.Modifiers[#self.Modifiers]
	if LastModifier then 
		Audio.Wire(LastModifier, Modifier, self)
	else
		Audio.Wire(self.ProducerInstance, Modifier, self)
	end

	Modifier.Destroying:Once(function()
		self:RemoveModifier(Modifier)
	end)

	table.insert(self.Modifiers, Modifier)

	Audio.UpdateConsumers(self, LastModifier)
	self.ModifierAdded:Fire(Modifier)
	
	return self
end

function AudioGraph:RemoveModifier(Modifier: AudioModifierInstance): typeof(AudioGraph)
	assert(Modifier.Name ~= "_MainVolume", "You cannot delete the _MainVolume modifier!")
	local index = table.find(self.Modifiers, Modifier)
	self.ModifierRemoving:Fire(Modifier)

	if self.Wires[Modifier] then
		for _, wire in pairs(self.Wires[Modifier]) do
			local Source = wire.SourceInstance
			local NextModifier = self.Modifiers[index + 1]
			table.remove(self.Wires[Modifier], table.find(self.Wires[Modifier], wire))
			wire:Destroy()
			
			if not NextModifier then continue end
			for _, wire in pairs(self.Wires[NextModifier]) do
				if wire.SourceInstance == Modifier  then
					table.remove(self.Wires[NextModifier], table.find(self.Wires[NextModifier], wire))
					wire:Destroy()
					Audio.Wire(Source, NextModifier, self)
				end
			end
		end
	end

	table.remove(self.Modifiers, index)
	Audio.UpdateConsumers(self, Modifier)
	
	return self
end

function AudioGraph:ConnectConsumer(Consumer: AudioConsumerInstance & Instance): typeof(AudioGraph)
	if not Consumer.Parent then 
		Consumer.Parent = self.ProducerInstance.Consumers
	end

	local LastModifier = self.Modifiers[#self.Modifiers] or self.ProducerInstance
	Audio.Wire(LastModifier, Consumer, self)

	table.insert(self.Consumers, Consumer)
	Consumer.Destroying:Once(function()
		print(`Consumer {Consumer} is destroying`)
		self:RemoveConsumer(Consumer)
	end)
	 
	self.ConsumerAdded:Fire(Consumer)
	
	return self
end

function AudioGraph:RemoveConsumer(Consumer: AudioConsumerInstance): typeof(AudioGraph)
	local ConsumerWires = self.Wires[Consumer]
	
	if ConsumerWires then
		for _, wire in pairs(ConsumerWires) do
			wire:Destroy()
			table.remove(self.Wires[Consumer], table.find(self.Wires[Consumer], wire))
		end
	end
	
	table.remove(self.Consumers, table.find(self.Consumers, Consumer))
	self.ConsumerRemoved:Fire(Consumer)
	
	return self
end

function AudioGraph:GetAudioInstance(Name: string): AudioModifierInstance | AudioConsumerInstance
	local AudioInstance 

	for _, Modifier in pairs(self.Modifiers) do
		if Modifier.Name == Name then
			AudioInstance = Modifier
			break
		end
	end
	if AudioInstance then return AudioInstance end

	for _, Consumer in pairs(self.Consumers) do
		if Consumer.Name == Name then
			AudioInstance = Consumer
			break
		end
	end
	
	return AudioInstance
end

function AudioGraph:Branch(Modifier: AudioModifierInstance & Instance, DestroyAllOnCleanup: boolean): typeof(AudioGraph)
	if not self:GetAudioInstance(Modifier.Name) then error("Attempted to branch off of non existent modifier!") end
	
	local NewGraph = Audio.NewGraph(Modifier) -- typechecking wont like this but itll work

	NewGraph.BranchingFrom = self
	NewGraph.DestroyAll = DestroyAllOnCleanup
	
	table.insert(self.Branches, NewGraph)
	return NewGraph
end

function AudioGraph:Cleanup(DestroyAll)
	for _, Item in pairs(self.Wires) do
		for _, Wire in pairs(Item) do
			Wire:Destroy()
		end
	end
	
	for _, Modifier in pairs(self.Modifiers) do
		if DestroyAll then
			Modifier:Destroy()
		else
			self:RemoveModifier(Modifier)
		end
	end
	
	for _, Consumer in pairs(self.Consumers) do
		if DestroyAll then
			Consumer:Destroy()
		else
			self:RemoveModifier(Consumer)
		end
	end
	
	if DestroyAll then
		self.ProducerInstance:Destroy()
	else
		table.remove(Audio.Graphs, table.find(Audio.Graphs, self))
	end
end

function AudioGraph:Duck(AudioInstance: AudioProducerInstance | AudioModifierInstance, CompressorProperties: {}): typeof(AudioGraph)
	local DuckCompressor = self:GetAudioInstance("_DuckCompressor") or self:CreateModifier("Compressor", {Name = "_DuckCompressor"})
	
	local Wire = Instance.new("Wire")
	Wire.TargetName = "Sidechain"
	Wire.SourceInstance = AudioInstance
	Wire.TargetInstance = DuckCompressor
	
	Wire.Parent = DuckCompressor
	Wire.Name = `{AudioInstance}ToSidechain{DuckCompressor}`
	
	table.insert(self.SidechainWires, Wire)
	
	self.DuckConnection = AudioInstance.Destroying:Once(function()
		self:ReleaseDuck()
	end)
	
	if not CompressorProperties then return self end
	for property, value in ipairs(CompressorProperties) do
		DuckCompressor[property] = value
	end
	
	return self
end

function AudioGraph:ReleaseDuck(): typeof(AudioGraph)
	local DuckCompressor = self:GetAudioInstance("_DuckCompressor")
	if not DuckCompressor then warn("AudioGraph isn't ducked!") return self end
	
	for i, Wire in pairs(self.SidechainWires) do
		if Wire.TargetInstance == DuckCompressor then
			Wire:Destroy()
			table.remove(self.SidechainWires, i)
		end
	end
	
	if self.DuckConnection then
		self.DuckConnection:Disconnect()
	end
	
	DuckCompressor:Destroy()
	
	return self
end

function Audio.Wire(Source: AudioProducerInstance | AudioModifierInstance, Target: AudioConsumerInstance | AudioModifierInstance, Graph: typeof(AudioGraph))
	local Wire = Instance.new("Wire")

	Wire.Parent = Target
	Wire.SourceInstance = Source
	Wire.TargetInstance = Target
	Wire.Name = `{Source.Name}To{Target.Name}`

	if not Graph.Wires[Target] then
		Graph.Wires[Target] = {Wire}
	else
		table.insert(Graph.Wires[Target], Wire)
	end
end

function Audio.UpdateConsumers(Graph: typeof(AudioGraph), OldModifier: AudioModifierInstance)
	for _, Consumer in ipairs(Graph.Consumers) do
		local LastModifier = Graph.Modifiers[#Graph.Modifiers] or Graph.ProducerInstance
		local ConsumerWires = Graph.Wires[Consumer]
		if not ConsumerWires then continue end

		for _, ConsumerWire in ipairs(ConsumerWires) do
			if ConsumerWire.SourceInstance ~= OldModifier then continue end

			ConsumerWire:Destroy()
			table.remove(Graph.Wires[Consumer], table.find(Graph.Wires[Consumer], ConsumerWire))
			Audio.Wire(LastModifier, Consumer, Graph)
		end
	end
end

function Audio.GetFirstGraph(Producer: AudioProducerInstance): typeof(AudioGraph) | nil
	for _, ProducerClass in ipairs(Audio.Graphs) do
		if ProducerClass.ProducerInstance == Producer then
			return ProducerClass
		end
	end
	
	return nil
end

export type AudioGraph = typeof(AudioGraph)

return Audio
