function [data, event] = xdf2fieldtrip(filename, varargin)

% XDF2FIELDTRIP reads data from a XDF file with multiple streams. It upsamples the
% data of all streams to the highest sampling rate and concatenates all channels in
% all streams into a raw data structure that is compatible with the output of
% FT_PREPROCESSING.
%
% Use as
%   [data, events] = xdf2fieldtrip(filename, ...)
%
% Optional arguments should come in key-value pairs and can include
%   streamindx  = list, indices of the streams to read (default is all)
%
% You can also use the standard procedure with FT_DEFINETRIAL and FT_PREPROCESSING
% for XDF files. This will return (only) the stream with the highest sampling rate,
% which is typically the EEG.
%
% You can use FT_READ_EVENT to read the events from the non-continuous data streams.
% To get them aligned with the samples in one of the specific data streams, you
% should specify the corresponding header structure.
%
% See also FT_PREPROCESSING, FT_DEFINETRIAL, FT_REDEFINETRIAL

% Copyright (C) 2019, Robert Oostenveld
%
% This file is part of FieldTrip, see http://www.fieldtriptoolbox.org
% for the documentation and details.
%
%    FieldTrip is free software: you can redistribute it and/or modify
%    it under the terms of the GNU General Public License as published by
%    the Free Software Foundation, either version 3 of the License, or
%    (at your option) any later version.
%
%    FieldTrip is distributed in the hope that it will be useful,
%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%    GNU General Public License for more details.
%
%    You should have received a copy of the GNU General Public License
%    along with FieldTrip. If not, see <http://www.gnu.org/licenses/>.
%
% $Id$

% process the options
streamindx = ft_getopt(varargin, 'streamindx');

% ensure this is on the path
ft_hastoolbox('xdf', 1);

% read all streams
streams = load_xdf(filename);
iscontinuous = false(size(streams));
% figure out which streams contain continuous/regular and discrete/irregular data
for i=1:numel(streams)
  iscontinuous(i) = isfield(streams{i}.info, 'effective_srate');
end

% give some feedback
for i=1:numel(streams)
  if iscontinuous(i)
    ft_info('stream %d contains continuous %s data\n', i, streams{i}.info.name);
  else
    ft_info('stream %d contains non-continuous %s data\n', i, streams{i}.info.name);
  end
end

% Read the EEG stream to get the first time stamp
EEG_t1=[];
for i=1:length(streams)
    if (strcmp(streams{i}.info.type,'EEG'))
        temp= str2double(streams{i}.info.first_timestamp);
        EEG_t1=[EEG_t1;temp];
    end
end

if isempty(EEG_t1)
  ft_error('Data doesnot contain an EEG stream');
end

% Find the EEG stream with earliest time stamp. In case of two EEG streams
% with variable sampling rates; e.g 128 Hz vs 1000 Hz
EEG_t1_min= min(EEG_t1);

% Select Non continuous Marker streams
ismarker=false(size(streams));
for i=1:numel(streams)
    ismarker(i)=strcmp(streams{i}.info.type,'Markers');
end
MarkerStreams=streams(ismarker);

% select the streams to continue working with
if isempty(streamindx)
  selected = true(size(streams));
else
  selected = false(size(streams));
  selected(streamindx) = true;
end

% discard the non-continuous streams for further processing
streams = streams(iscontinuous & selected);

if isempty(streams)
  ft_error('no continuous streams were selected');
end

% convert each continuous stream into a FieldTrip raw data structure
data = cell(size(streams));
for i=1:numel(streams)
  
  % make a copy for convenience
  stream = streams{i};
  
  % this section of code is shared with fileio/private/sccn_xdf
  hdr             = [];
  hdr.Fs          = stream.info.effective_srate;
  hdr.nChans      = numel(stream.info.desc.channels.channel);
  hdr.nSamplesPre = 0;
  hdr.nSamples    = length(stream.time_stamps);
  hdr.nTrials     = 1;
  hdr.label       = cell(hdr.nChans, 1);
  hdr.chantype    = cell(hdr.nChans, 1);
  hdr.chanunit    = cell(hdr.nChans, 1);
  
  prefix = stream.info.name;
  
  for j=1:hdr.nChans
    hdr.label{j} = [prefix '_' stream.info.desc.channels.channel{j}.label];
    hdr.chantype{j} = stream.info.desc.channels.channel{j}.type;
    hdr.chanunit{j} = stream.info.desc.channels.channel{j}.unit;
  end
  
  hdr.FirstTimeStamp     = stream.time_stamps(1);
  hdr.TimeStampPerSample = (stream.time_stamps(end)-stream.time_stamps(1)) / (length(stream.time_stamps) - 1);
  
  % keep the original header details
  hdr.orig = stream.info;

  data{i}.hdr = hdr;
  data{i}.label = hdr.label;
  data{i}.time = {streams{i}.time_stamps};
  data{i}.trial = {streams{i}.time_series};
  %data{i}.event = events;
  
end % for all continuous streams

% determine the continuous stream with the highest sampling rate
srate = nan(size(streams));
for i=1:numel(streams)
  srate(i) = streams{i}.info.effective_srate;
end
[max_srate, indx] = max(srate);

if numel(data)>1
  % resample all data structures, except the one with the max sampling rate
  % this will also align the time axes
  for i=1:numel(data)
    if i==indx
      continue
    end
    
    ft_notice('resampling %s', streams{i}.info.name);
    cfg = [];
    cfg.time = data{indx}.time;
    data{i} = ft_resampledata(cfg, data{i});
  end
  
  % append all data structures
  data = ft_appenddata([], data{:});
else
  % simply return the first and only one
  data = data{1};
end
% Read the events

events = [];
event = struct('sample', [], 'offset', [], 'duration', num2cell(ones(1, length(MarkerStreams{i}.time_stamps))),...
                'type', cellstr(repmat({'Marker'}, 1, length(MarkerStreams{i}.time_stamps))), 'value', ' ', 'timestamp', []); 
for i=1:length(MarkerStreams)
        try
            for k=1:length(MarkerStreams{i}.time_stamps)
                if iscell(MarkerStreams{i}.time_series)
                    event(k).value = MarkerStreams{i}.time_series{k};
                else
                    event(k).value = num2str(MarkerStreams{i}.time_series(k));
                end
                event(k).sample = round((MarkerStreams{i}.time_stamps(k)- EEG_t1_min)*max_srate);
                event(k).timestamp = MarkerStreams{i}.time_stamps(k);
            end
            events = [events, event]; 
        catch err
            ft_info('Could not interpret event stream named "', MarkerStreams{i}.info.name, '": ', err.message);
        end
end
